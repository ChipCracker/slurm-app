import SwiftUI

/// Which log stream a `LogDetailSheetView` shows. Limited to the two
/// streams the detail pane renders as expandable "log windows".
enum LogStream {
    case stdout, stderr
}

/// Payload for the full-size log modal. Carries the *live* view-model
/// reference (not a snapshot) so Follow-mode keeps streaming into the
/// modal while it's open. `JobsView` presents it via `.glassModal(item:)`,
/// so it has to be `Identifiable`.
struct LogModalSelection: Identifiable {
    let vm: JobDetailViewModel
    let stream: LogStream
    /// Captured at construction so `id` stays nonisolated (vm.job is now
    /// MainActor-isolated @Published state).
    let jobId: String
    var id: String {
        let key = stream == .stderr ? "stderr" : "stdout"
        return "\(key)-\(jobId)"
    }
}

@MainActor
final class JobDetailViewModel: ObservableObject {
    @Published var details: JobDetails?
    @Published var script: String = ""
    @Published var stdout: String = ""
    @Published var stderr: String = ""
    @Published var stdoutPath: String?
    @Published var stderrPath: String?
    @Published var gpuStats: [GpuStat] = []
    @Published var maxRssMB: Double?
    @Published var liveError: String?
    @Published var loading = false
    @Published var initialLoadDone: Bool = false
    /// Per-section load flags so a slow log tail or batch-script fetch only
    /// shimmers its own card instead of holding the whole detail in skeleton.
    @Published var logsLoaded: Bool = false
    @Published var scriptLoaded: Bool = false
    @Published var error: String?
    @Published var followMode: Bool = false
    @Published var availableQos: [String] = []
    @Published var availablePartitions: [String] = []
    /// Whether each log stream actually returned content (vs. a placeholder like
    /// "[kein stderr-Pfad]"). The placeholder strings are never empty, so
    /// emptiness can't be used to decide which stream is "active".
    @Published var stdoutHasContent: Bool = false
    @Published var stderrHasContent: Bool = false

    /// The job snapshot — `@Published var` (not `let`) so a state/runtime change
    /// from the jobs poll flows in (the view's `.id(job.id)` keeps the same VM
    /// instance, so without this the header, gating and live-GPU poll froze at
    /// selection time). Synced by the view via `.onChange(of: job)`.
    @Published var job: Job
    private weak var appState: AppState?
    // Reentrancy guards: the initial load() and the 5s poll can both fire a
    // refresh; the flag is set synchronously on the MainActor before any await,
    // so a concurrent call returns instead of double-issuing SSH commands.
    private var statsInFlight = false
    private var logsInFlight = false
    /// MaxRSS bewegt sich im Minutentakt — eigene, langsamere Kadenz als die
    /// 5s-GPU-Stats, damit `sstat` (für Nicht-Batch-Jobs bis zu zwei Aufrufe)
    /// nicht jeden Tick die serielle SSH-Queue belegt.
    private var lastRssFetch: Date = .distantPast
    static let rssRefreshInterval: TimeInterval = 30

    init(job: Job) { self.job = job }

    func bind(_ s: AppState) { self.appState = s }

    func load() async {
        // Debounce rapid cursor movement: arrow-keying past this row cancels the
        // task before we fire the per-selection SSH storm. 250 ms is below human
        // dwell time but skips intermediate rows.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        // Always settle the skeleton state, even on an early exit — otherwise a
        // detail pane opened while disconnected would shimmer forever.
        defer {
            if !initialLoadDone {
                withMotion(.smooth(duration: 0.4)) { initialLoadDone = true }
            }
        }
        guard let slurm = appState?.slurm else { return }
        loading = true; defer { loading = false }
        do {
            let details = try await slurm.fetchJobDetails(job.jobId)
            self.details = details
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
        // Core details are in → dismiss the stats-grid skeletons immediately.
        // Everything below is independent: each card owns its loading flag so a
        // slow/stuck command on the shared, serialized SSH link can't keep the
        // whole detail shimmering forever.
        if !initialLoadDone {
            withMotion(.smooth(duration: 0.4)) { initialLoadDone = true }
        }

        // Logs use the paths from `details`; render an "(no log path)" card
        // rather than a missing one even when scontrol show job throws.
        await refreshLogs()
        logsLoaded = true

        self.script = (try? await slurm.fetchBatchScript(job.jobId)) ?? ""
        scriptLoaded = true

        // QoS/partition lists are cluster-static and only needed when the pills
        // are editable (own, not-finished job). Skip the two SSH round-trips
        // entirely otherwise, and serve them from the connection-wide cache so
        // arrow-keying through rows doesn't refetch them per selection.
        let me = appState?.credentials?.username
        let editable = job.user == me && (job.isRunning || job.isPending)
        if editable, let appState {
            self.availableQos = await appState.cachedAvailableQos()
            self.availablePartitions = await appState.cachedAvailablePartitions()
        }
    }

    func updateQos(_ newQos: String) async -> String? {
        guard let slurm = appState?.slurm else { return nil }
        do {
            let result = try await slurm.updateJobQos(job.jobId, qos: newQos)
            return result.isEmpty ? "QoS auf \(newQos) gesetzt." : result
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    func updatePartition(_ newPartition: String) async -> String? {
        guard let slurm = appState?.slurm else { return nil }
        do {
            let result = try await slurm.updateJobPartition(job.jobId, partition: newPartition)
            return result.isEmpty ? "Partition auf \(newPartition) gesetzt." : result
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    func refreshLogs() async {
        guard !logsInFlight else { return }
        logsInFlight = true; defer { logsInFlight = false }
        guard let slurm = appState?.slurm else { return }
        let rawOut = details?.stdOut.flatMap { $0 == "(null)" ? nil : $0 }
        let rawErr = details?.stdErr.flatMap { $0 == "(null)" ? nil : $0 }
        let outPath = rawOut.map { expandSlurmPath($0) }
        let errPath = rawErr.map { expandSlurmPath($0) }
        // Nur bei echter Änderung publizieren (Gegenstück zum Diff in
        // JobsViewModel.refresh): Im Follow-Mode liefert tailLog meist
        // dieselben 200 Zeilen — ohne die Guards würde jeder 5s-Tick die
        // gesamte Detail-Ansicht (inkl. der Monospace-Log-Texte) mehrfach
        // neu rendern, obwohl sich nichts geändert hat.
        if self.stdoutPath != outPath { self.stdoutPath = outPath }
        if self.stderrPath != errPath { self.stderrPath = errPath }

        let out = await readLog(slurm: slurm, path: outPath, stream: "stdout")
        let err = await readLog(slurm: slurm, path: errPath, stream: "stderr")
        if self.stdout != out.text { self.stdout = out.text }
        if self.stdoutHasContent != out.hasContent { self.stdoutHasContent = out.hasContent }
        if self.stderr != err.text { self.stderr = err.text }
        if self.stderrHasContent != err.hasContent { self.stderrHasContent = err.hasContent }
    }

    private func readLog(slurm: SlurmService, path: String?, stream: String) async -> (text: String, hasContent: Bool) {
        guard let path, !path.isEmpty else {
            return ("[Kein \(stream)-Pfad in scontrol show job]", false)
        }
        do {
            let text = try await slurm.tailLog(path: path, lines: 200)
            return text.isEmpty ? ("[\(stream) ist (noch) leer]\n\(path)", false) : (text, true)
        } catch {
            return ("[Konnte \(stream) nicht lesen: \(error.localizedDescription)]\n\(path)", false)
        }
    }

    /// Slurm log paths often contain `%j`, `%x`, `%u`, `%A`, `%a` placeholders.
    /// Most slurmd-installations expand these before exposing the path via
    /// `scontrol show job`, but some don't — expand them ourselves as a
    /// fallback so `tail` doesn't choke on the literal `%j`.
    private func expandSlurmPath(_ raw: String) -> String {
        var s = raw
        let jobId = job.jobId
        let baseId = jobId.split(separator: "_").first.map(String.init) ?? jobId
        let arrayIdx = jobId.contains("_") ? String(jobId.split(separator: "_").last ?? "") : "0"
        s = s.replacingOccurrences(of: "%j", with: jobId)
        s = s.replacingOccurrences(of: "%A", with: baseId)
        s = s.replacingOccurrences(of: "%a", with: arrayIdx)
        s = s.replacingOccurrences(of: "%x", with: job.name)
        s = s.replacingOccurrences(of: "%u", with: job.user)
        return s
    }

    func refreshLiveStats() async {
        guard !statsInFlight else { return }
        statsInFlight = true; defer { statsInFlight = false }
        guard let slurm = appState?.slurm, job.isRunning else { return }
        do {
            let stats = try await slurm.liveGpuStats(jobId: job.jobId)
            // Diff vor dem Publish — siehe refreshLogs: bei ruhigen Jobs ist
            // die nvidia-smi-Ausgabe oft tick-für-tick identisch.
            if stats != gpuStats { self.gpuStats = stats }
            if liveError != nil { self.liveError = nil }
        } catch {
            let msg = error.localizedDescription
            if liveError != msg { self.liveError = msg }
        }
        // MaxRSS höchstens alle 30s statt jeden 5s-Tick abfragen — fetchJobMemoryMB
        // probiert "<id>.batch" UND "<id>", also bis zu zwei sstat-Roundtrips,
        // die sonst die serielle SSH-Queue vor Nutzeraktionen blockieren.
        if Date().timeIntervalSince(lastRssFetch) >= Self.rssRefreshInterval {
            lastRssFetch = Date()
            let rss = try? await slurm.fetchJobMemoryMB(job.jobId)
            if maxRssMB != rss { self.maxRssMB = rss }
        }
    }
}

struct JobDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bookmarks: BookmarksStore
    /// Fresh job snapshot from the parent on every render. The view identity is
    /// `.id(job.id)`, so it stays stable across state changes — this property
    /// carries the new state/runtime in and is synced into the VM below.
    let job: Job
    @StateObject private var vm: JobDetailViewModel
    @State private var showCancelConfirm = false
    @State private var actionMessage: String?
    /// Optimistischer Cancel-Zustand: Nach erfolgreichem scancel zeigt der
    /// Header CANCELLING… und der Button bleibt entwaffnet, bis der Jobs-Poll
    /// einen echten Statuswechsel liefert — sonst bliebe der Job bis zu 10s
    /// scheinbar RUNNING und ein zweites scancel möglich.
    @State private var cancelRequested = false
    /// True, während der scancel-Roundtrip auf der seriellen SSH-Queue läuft.
    @State private var cancelInFlight = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Eine Spalte auf dem iPhone (kompakte Breite), damit lange Werte nicht
    /// abgeschnitten werden; zwei Spalten auf iPad/macOS.
    private var statColumns: [GridItem] {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            return [GridItem(.flexible(), spacing: 16)]
        }
        #endif
        return [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    /// Hands an expand request up to `JobsView`, which owns the glass modal
    /// so it dims the whole window and joins the shared Esc / Space-close /
    /// focus-restore machinery. Defaults to a no-op for previews.
    private let onExpandLog: (LogModalSelection) -> Void

    init(job: Job, onExpandLog: @escaping (LogModalSelection) -> Void = { _ in }) {
        self.job = job
        _vm = StateObject(wrappedValue: JobDetailViewModel(job: job))
        self.onExpandLog = onExpandLog
    }

    var body: some View {
        ZStack {
            SlurmyPaneBackground().ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header.id("header")
                        statsGrid
                        if showsLiveGpu {
                            liveStatsCard.id("liveGpu")
                        }
                        scriptSection(initialLoading: !vm.scriptLoaded)
                        logSection(
                            title: "stderr", body: vm.stderr, color: Theme.danger,
                            initialLoading: !vm.logsLoaded
                        )
                        logSection(
                            title: "stdout", body: vm.stdout, color: Theme.success,
                            initialLoading: !vm.logsLoaded
                        ).id("logs")
                        if let msg = actionMessage {
                            ErrorBanner(message: msg, tint: Theme.warning)
                        }
                        if let err = vm.error {
                            ErrorBanner(message: err)
                        }
                        actions
                    }
                    .padding()
                }
                #if os(iOS)
                .refreshable { await vm.load() }   // Pull-to-refresh (touch)
                #endif
                .background(detailShortcuts(proxy: proxy))
            }
        }
        .task {
            vm.bind(appState)
            await vm.load()
            // Kick off the first GPU fetch right away so the live card settles
            // instead of shimmering for a full refresh cycle before any data.
            if showsLiveGpu { await vm.refreshLiveStats() }
        }
        // Periodic log + GPU stat refresh — only while the window is in the
        // foreground (no srun/nvidia-smi every 5s when hidden). GPU stats only
        // run for the current user's running, GPU-bearing jobs.
        .task(id: scenePhase) {
            vm.bind(appState)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                if Task.isCancelled { break }
                if vm.followMode { await vm.refreshLogs() }
                if showsLiveGpu { await vm.refreshLiveStats() }
            }
        }
        // Keep the VM's job snapshot live as the jobs poll updates this row, so
        // the header/runtime tick, PD→R reveals the live-GPU card and starts the
        // poll, and a finished job stops the 5s srun loop instead of hammering a
        // dead allocation forever.
        .onChange(of: job) { oldJob, newJob in
            if vm.job != newJob { vm.job = newJob }
            // Echter Statuswechsel vom Poll → der optimistische
            // CANCELLING-Zustand ist erledigt, Slurm-Status zeigt wieder.
            if cancelRequested && oldJob.state != newJob.state {
                cancelRequested = false
            }
        }
        .alert("Job abbrechen?", isPresented: $showCancelConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Bestätigen", role: .destructive) { Task { await cancel() } }
        } message: {
            Text("Job \(vm.job.jobId) wird mit scancel beendet.")
        }
        // Space inside the detail pane is routed here by JobsView (a single
        // global Space binding lives there). We open the *active* log so the
        // user doesn't have to aim — closing again is handled by JobsView's
        // closeTopmostModal, which makes Space a clean toggle.
        .onReceive(NotificationCenter.default.publisher(for: .requestExpandActiveLog)) { _ in
            expandActiveLog()
        }
    }

    /// Open the more relevant of the two log windows: stderr when it has
    /// content (errors are what you usually want to read), otherwise stdout.
    private func expandActiveLog() {
        // Pick stderr only when it has REAL content (placeholders are non-empty,
        // so `!stderr.isEmpty` always picked stderr and stdout was unreachable).
        let stream: LogStream = vm.stderrHasContent ? .stderr : .stdout
        onExpandLog(LogModalSelection(vm: vm, stream: stream, jobId: vm.job.jobId))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Theme.stateColor(vm.job.state)).frame(width: 10, height: 10)
                Text(vm.job.jobId).font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Job-ID kopieren") { Clipboard.copy(vm.job.jobId) }
                        Button("Name kopieren") { Clipboard.copy(vm.job.name) }
                    }
                Spacer()
                Text(displayedState).font(.caption.bold()).foregroundColor(displayedStateColor)
                    .contentTransition(.opacity)
                    .motion(Motion.smooth, value: displayedState)
                Button {
                    bookmarks.add(Bookmark(jobId: vm.job.jobId, label: vm.job.name))
                    actionMessage = "Bookmark gespeichert."
                } label: {
                    Image(systemName: "bookmark")
                        .foregroundColor(Theme.accent)
                        .iosTouchTarget()
                }
                .buttonStyle(.plain)
                .help("Job als Bookmark speichern")
            }
            Text(vm.job.name).font(.title2).foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .contextMenu { Button("Name kopieren") { Clipboard.copy(vm.job.name) } }
            HStack(spacing: 8) {
                pillOrPicker(
                    label: vm.job.partition,
                    color: Theme.cyan,
                    editable: isOwnJob && vm.job.isPending,
                    options: vm.availablePartitions,
                    currentValue: vm.job.partition
                ) { newValue in
                    Task {
                        let msg = await vm.updatePartition(newValue)
                        if let msg { actionMessage = msg }
                    }
                }
                pillOrPicker(
                    label: "QoS \(vm.job.qos)",
                    color: Theme.qosColor(vm.job.qos),
                    editable: isOwnJob && (vm.job.isRunning || vm.job.isPending),
                    options: vm.availableQos,
                    currentValue: vm.job.qos
                ) { newValue in
                    Task {
                        let msg = await vm.updateQos(newValue)
                        if let msg { actionMessage = msg }
                    }
                }
                if vm.job.gpus > 0 { tag("\(vm.job.gpus) GPU", color: Theme.success) }
                tag("\(vm.job.cpus) CPU", color: Theme.warning)
            }
        }
        .cardStyle()
    }

    /// Renders the standard `tag` pill. When `editable` is true and `options`
    /// are available, the pill itself becomes a Menu trigger and gets a small
    /// pencil glyph; the appearance otherwise stays identical to the read-only
    /// pill so the current Partition/QoS is always visible.
    @ViewBuilder
    private func pillOrPicker(
        label: String,
        color: Color,
        editable: Bool,
        options: [String],
        currentValue: String,
        onChange: @escaping (String) -> Void
    ) -> some View {
        if editable && !options.isEmpty {
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button(opt) { if opt != currentValue { onChange(opt) } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label).font(.caption.bold())
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .opacity(0.7)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color.opacity(0.18))
                .foregroundColor(color)
                .clipShape(Capsule())
                // Einziger Weg, QoS/Partition für einen Einzeljob per Touch zu
                // ändern — die ~24pt-Kapsel allein verfehlt Apples 44pt-Minimum.
                .iosTouchTarget()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Klicken zum Ändern")
        } else {
            tag(label, color: color)
        }
    }

    /// Compact two-column block of label/value rows in a single card. Long
    /// fields (Command) get a full-width row underneath the grid so paths
    /// stay readable.
    private var statsGrid: some View {
        let pending = !vm.initialLoadDone
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(
                columns: statColumns,
                alignment: .leading,
                spacing: 6
            ) {
                // Begriffe deckungsgleich mit Tabelle/Sortmenü: „Laufzeit",
                // „Speicher", „Node", „User", „Grund" — Slurm-Jargon (QoS,
                // Account, MaxRSS, Limit) bleibt unübersetzt.
                compactStat("Laufzeit", vm.job.runtime)
                compactStat("Limit",
                            vm.details?.timeLimit ?? "00:00:00",
                            isSkeleton: vm.details?.timeLimit == nil && pending)
                compactStat("Speicher", vm.job.memory)
                compactStat("Node", vm.job.node)
                compactStat("User", vm.job.user)
                compactStat("Account",
                            vm.details?.account ?? "—",
                            isSkeleton: vm.details?.account == nil && pending)
                if let rss = vm.maxRssMB {
                    compactStat("MaxRSS", formatMB(rss))
                } else if pending && vm.job.isRunning {
                    compactStat("MaxRSS", "0.0 GB", isSkeleton: true)
                }
                if !vm.job.reason.isEmpty {
                    compactStat("Grund", vm.job.reason)
                }
            }
            if let cmd = vm.details?.command {
                commandRow(cmd, isSkeleton: false)
            } else if pending {
                commandRow("/path/to/script.sh", isSkeleton: true)
            }
        }
        .padding(10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func compactStat(_ label: String, _ value: String, isSkeleton: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .redacted(reason: isSkeleton ? .placeholder : [])
        .shimmering(isSkeleton)
        .motion(.smooth(duration: 0.4), value: value)
    }

    @ViewBuilder
    private func commandRow(_ value: String, isSkeleton: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Command")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .redacted(reason: isSkeleton ? .placeholder : [])
        .shimmering(isSkeleton)
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private var liveStatsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.purple.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "cpu.fill")
                        .font(.title3)
                        .foregroundColor(Theme.purple)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live GPU Stats")
                        .font(.title3.bold())
                        .foregroundColor(Theme.textPrimary)
                    Text("nvidia-smi via srun --overlap")
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Theme.success).frame(width: 7, height: 7)
                    Text("5s")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.surfaceElevated)
                .clipShape(Capsule())
            }
            Group {
                if let err = vm.liveError {
                    ErrorBanner(message: err)
                        .font(.callout.monospaced())
                        .transition(.opacity)
                } else if vm.gpuStats.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.skeletonGpuStats) { stat in
                            gpuRow(stat)
                        }
                    }
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.gpuStats) { stat in
                            gpuRow(stat)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
                    // Animate value changes on each 5s refresh: bars glide to
                    // the new util/mem, numbers roll (see .contentTransition).
                    .motion(.smooth(duration: 0.5), value: vm.gpuStats)
                }
            }
            .motion(.smooth(duration: 0.4), value: vm.gpuStats.isEmpty)
        }
        .padding(18)
        .background(
            ZStack {
                Theme.surface
                LinearGradient(
                    colors: [Theme.purple.opacity(0.12), Theme.accent.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.purple.opacity(0.35), lineWidth: 1)
        )
    }

    private static let skeletonGpuStats: [GpuStat] = (0..<2).map { i in
        GpuStat(
            slot: i,
            index: i,
            name: "NVIDIA A100-SXM4-40GB",
            utilizationPercent: 45,
            memoryUsedMiB: 16_384,
            memoryTotalMiB: 40_960,
            powerDrawW: 220,
            powerLimitW: 400,
            temperatureC: 62
        )
    }

    private func gpuRow(_ stat: GpuStat) -> some View {
        // GPU live stats: full utilisation is good (efficient) → green; low is
        // neutral grey, not an alarm. (See Theme.gpuUtilColor.)
        let utilColor = Theme.gpuUtilColor(Double(stat.utilizationPercent) / 100)
        let memColor  = Theme.gpuUtilColor(stat.memoryRatio)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("GPU \(stat.index)")
                    .font(.callout.bold().monospaced())
                    .foregroundColor(Theme.textPrimary)
                Text(stat.name)
                    .font(.caption.monospaced())
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Label("\(stat.temperatureC)°C", systemImage: "thermometer.medium")
                    .font(.caption.monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .contentTransition(.numericText())
                    .foregroundColor(stat.temperatureC > 75 ? Theme.danger : Theme.textSecondary)
                Label(String(format: "%.0fW", stat.powerDrawW), systemImage: "bolt.fill")
                    .font(.caption.monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .contentTransition(.numericText())
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 12) {
                metricBar(label: "util", value: "\(stat.utilizationPercent)%",
                          ratio: Double(stat.utilizationPercent) / 100, color: utilColor)
                metricBar(
                    label: "mem",
                    value: "\(stat.memoryUsedMiB / 1024)/\(stat.memoryTotalMiB / 1024) GB",
                    ratio: stat.memoryRatio,
                    color: memColor
                )
            }
        }
        .padding(12)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metricBar(label: String, value: String, ratio: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased())
                    .font(.caption2.bold())
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Hairline um den Track: In hellen Themes liegt der Track
                    // (background ≈ surfaceElevated) sonst unsichtbar auf der
                    // Karte, und bei niedrigen Ratios (graue Füllung, siehe
                    // Theme.gpuUtilColor) wirkt der ganze Balken leer.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.background.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(3, CGFloat(min(1, max(0, ratio))) * geo.size.width))
                }
            }
            .frame(height: 9)
        }
    }

    @ViewBuilder
    private func scriptSection(initialLoading: Bool) -> some View {
        Group {
            if !vm.script.isEmpty {
                scriptCard
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if initialLoading {
                skeletonScriptCard
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func logSection(title: String, body: String, color: Color, initialLoading: Bool) -> some View {
        Group {
            if !body.isEmpty {
                logCard(title: title, body: body, color: color)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if initialLoading {
                skeletonLogCard(title: title, color: color)
                    .transition(.opacity)
            }
        }
    }

    /// Stand-in for the batch script while `scontrol write batch_script` is
    /// in flight. Uses a shellish dummy body so the redacted/shimmer overlay
    /// produces line shapes that resemble a real script.
    private var skeletonScriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Batch-Skript").font(.headline).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("lade…").font(.caption2).foregroundColor(Theme.textSecondary)
            }
            Text(Self.skeletonScriptBody)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
        .cardStyle()
        .redacted(reason: .placeholder)
        .shimmering()
    }

    private func skeletonLogCard(title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.headline).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("lade…").font(.caption2).foregroundColor(Theme.textSecondary)
            }
            Text(Self.skeletonLogBody)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
        .redacted(reason: .placeholder)
        .shimmering()
    }

    private static let skeletonScriptBody = """
    #!/bin/bash
    #SBATCH --partition=p2
    #SBATCH --gres=gpu:1
    #SBATCH --cpus-per-task=8
    #SBATCH --mem-per-cpu=4G

    module load cuda/12.4
    source ~/.venv/bin/activate
    python train.py --config configs/run.yaml
    """

    private static let skeletonLogBody = """
    [2026-05-27 12:34:56] starting epoch 1/100
    [2026-05-27 12:35:11] loss=2.4137 acc=0.21
    [2026-05-27 12:35:27] loss=1.8901 acc=0.34
    [2026-05-27 12:35:42] loss=1.5234 acc=0.48
    [2026-05-27 12:35:58] loss=1.2018 acc=0.57
    """

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Batch-Skript").font(.headline).foregroundColor(Theme.textPrimary)
                if let path = vm.details?.value("Command") {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                #if os(macOS)
                if isOwnJob, let path = vm.details?.value("Command"), !path.isEmpty {
                    Button {
                        editInTerminal(path: path)
                    } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.18))
                    .foregroundColor(Theme.accent)
                    .clipShape(Capsule())
                    .help("Öffnet das Skript mit $EDITOR (oder vim) in Terminal.app")
                }
                #endif
                Text("read-only").font(.caption2).foregroundColor(Theme.textSecondary)
            }
            ScrollView {
                Text(vm.script)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
        .cardStyle()
    }

    /// Open the remote script in $EDITOR (vim fallback) inside Terminal.app.
    /// The app itself never writes to the server — the user edits in a real
    /// PTY just like they would over plain ssh.
    private func editInTerminal(path: String) {
        guard let creds = appState.credentials else { return }
        TerminalLauncher.openSSH(
            host: creds.host,
            user: creds.username,
            port: creds.port,
            remoteCommand: "${EDITOR:-vim} \(path)"
        )
    }

    private func logCard(title: String, body: String, color: Color) -> some View {
        let path = (title == "stderr") ? vm.stderrPath : vm.stdoutPath
        let stream: LogStream = (title == "stderr") ? .stderr : .stdout
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Circle + title + expand glyph form one click target that
                // opens the full-size log modal. Kept off the body text so it
                // doesn't fight `.textSelection`. Echter Button statt
                // onTapGesture: Button-Trait + Aktion, damit das Log-Modal
                // auch per VoiceOver erreichbar ist.
                Button {
                    onExpandLog(LogModalSelection(vm: vm, stream: stream, jobId: vm.job.jobId))
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(title).font(.headline).foregroundColor(Theme.textPrimary)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.bold())
                            .foregroundColor(color)
                    }
                    // Einziger Touch-Weg zum Log-Modal (die Alternative, Leertaste,
                    // braucht eine Hardware-Tastatur) → 44pt-Trefferfläche auf iOS.
                    .iosTouchTarget()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Log vergrössert öffnen (Leertaste)")
                .accessibilityLabel("\(title)-Log vergrössern")
                if let p = path {
                    Text(p)
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                Spacer()
                Toggle(isOn: $vm.followMode) {
                    Label("Follow", systemImage: vm.followMode ? "play.fill" : "play")
                        .font(.caption.bold())
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Text("letzte 200 Zeilen").font(.caption2).foregroundColor(Theme.textSecondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(body)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logBottom-\(title)")
                }
                .frame(maxHeight: 260)
                .onChange(of: body) { _, _ in
                    if vm.followMode {
                        withMotion(.linear(duration: 0.15)) {
                            proxy.scrollTo("logBottom-\(title)", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await vm.load() }
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .background(Theme.surfaceElevated)
            .foregroundColor(Theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            #if os(macOS)
            if isOwnJob && vm.job.isRunning {
                Button {
                    if let creds = appState.credentials {
                        TerminalLauncher.attach(jobId: vm.job.jobId, credentials: creds)
                    }
                } label: {
                    Label("Attach", systemImage: "terminal")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .background(Theme.purple.opacity(0.18))
                .foregroundColor(Theme.purple)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .help("srun --overlap --pty bash in Terminal.app")
            }
            #endif

            if isOwnJob && (vm.job.isRunning || vm.job.isPending) {
                Button(role: .destructive) {
                    showCancelConfirm = true
                } label: {
                    Label(cancelRequested ? "scancel gesendet" : "scancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                // Entwaffnet, solange der Roundtrip läuft bzw. das scancel
                // schon raus ist — verhindert ein doppeltes scancel, bis der
                // Poll den echten Statuswechsel liefert.
                .disabled(cancelInFlight || cancelRequested)
                .background(Theme.danger.opacity(0.18))
                .foregroundColor(Theme.danger)
                .opacity(cancelInFlight || cancelRequested ? 0.5 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// Hidden buttons binding `f`/`v`/`l`/`Y` inside the detail pane.
    private func detailShortcuts(proxy: ScrollViewProxy) -> some View {
        ZStack {
            Shortcut.hiddenButton(.toggleFollow) {
                vm.followMode.toggle()
                actionMessage = "Follow-Mode: \(vm.followMode ? "an" : "aus")"
            }
            Shortcut.hiddenButton(.focusLiveGpu) {
                withMotion { proxy.scrollTo("liveGpu", anchor: .top) }
            }
            Shortcut.hiddenButton(.focusLogs) {
                withMotion { proxy.scrollTo("logs", anchor: .top) }
            }
            Shortcut.hiddenButton(.copyActiveLog) {
                // Wie expandActiveLog: Platzhalter ("[stderr ist (noch) leer]…")
                // sind nie leer — nur Streams mit ECHTEM Inhalt kopieren, sonst
                // landet Platzhaltertext statt des stdout in der Zwischenablage.
                let active = vm.stderrHasContent ? vm.stderr
                    : (vm.stdoutHasContent ? vm.stdout : "")
                if !active.isEmpty {
                    Clipboard.copy(active)
                    actionMessage = "Log kopiert (\(active.count) Zeichen)."
                } else {
                    actionMessage = "Kein Log-Inhalt vorhanden."
                }
            }
        }
    }

    /// True if the job belongs to the currently authenticated user.
    /// Live GPU stats and scancel are only offered for own jobs — Slurm
    /// rejects both for foreign jobs, and the UI shouldn't promise it can.
    private var isOwnJob: Bool {
        guard let me = appState.credentials?.username else { return false }
        return vm.job.user == me
    }

    /// Whether to show & poll the Live GPU Stats card. Only own, running jobs
    /// that actually requested GPUs — otherwise `srun --overlap nvidia-smi`
    /// lands on a GPU-less node and fails with "No devices were found".
    private var showsLiveGpu: Bool {
        isOwnJob && vm.job.isRunning && vm.job.gpus > 0
    }

    /// Header-Status: nach gesendetem scancel optimistisch CANCELLING…, bis
    /// der Jobs-Poll den echten Statuswechsel liefert.
    private var displayedState: String {
        cancelRequested ? "CANCELLING…" : vm.job.state
    }

    private var displayedStateColor: Color {
        cancelRequested ? Theme.danger : Theme.stateColor(vm.job.state)
    }

    private func cancel() async {
        guard let slurm = appState.slurm, !cancelInFlight else { return }
        cancelInFlight = true
        defer { cancelInFlight = false }
        do {
            _ = try await slurm.cancelJob(vm.job.jobId)
            // Optimistisch: Pill → CANCELLING…, Button entwaffnen und die
            // Jobliste sofort aktualisieren statt bis zu 10s auf den
            // nächsten stillen Poll zu warten (Listener: MainTabView).
            cancelRequested = true
            actionMessage = "scancel gesendet."
            NotificationCenter.default.post(name: .requestJobsRefresh, object: nil)
        } catch {
            actionMessage = "Fehler: \(error.localizedDescription)"
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// Full-size glass-modal view of a single log stream. Reads straight from
/// the detail pane's live view-model, so Follow-mode keeps streaming new
/// lines in while the modal is open. Presented by `JobsView`.
struct LogDetailSheetView: View {
    @ObservedObject var vm: JobDetailViewModel
    @State private var stream: LogStream
    @Environment(\.glassModalDismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(vm: JobDetailViewModel, stream: LogStream) {
        _vm = ObservedObject(wrappedValue: vm)
        _stream = State(initialValue: stream)
    }

    private var title: String { stream == .stderr ? "stderr" : "stdout" }
    private var color: Color { stream == .stderr ? Theme.danger : Theme.success }
    private var content: String { stream == .stderr ? vm.stderr : vm.stdout }
    private var path: String? { stream == .stderr ? vm.stderrPath : vm.stdoutPath }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.hairline)
            logBody
        }
        .background(
            Shortcut.hiddenButton(.toggleLogStream) {
                stream = (stream == .stderr) ? .stdout : .stderr
            }
        )
    }

    /// Kompakte Breite (iPhone): Die einzeilige Variante summiert sich auf
    /// ~450pt fixe Elemente und schiebt Copy/Close vom Schirm — daher dort
    /// zwei Zeilen (Titel + Schließen / Picker + Follow + Kopieren).
    private var isCompactWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var header: some View {
        if isCompactWidth {
            compactHeader
        } else {
            regularHeader
        }
    }

    private var regularHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 48, height: 48)
                Image(systemName: "doc.plaintext")
                    .font(.title2)
                    .foregroundColor(color)
            }
            titleBlock(font: .title2.bold())
            Spacer()
            streamPicker
                .fixedSize()
            followToggle

            SlurmyGlassButtonGroup {
                copyButton
                closeButton
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var compactHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 40, height: 40)
                    Image(systemName: "doc.plaintext")
                        .font(.title3)
                        .foregroundColor(color)
                }
                titleBlock(font: .headline)
                Spacer(minLength: 8)
                closeButton
            }
            HStack(spacing: 12) {
                streamPicker
                Spacer(minLength: 0)
                followToggle
                copyButton
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func titleBlock(font: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("\(vm.job.jobId) · \(vm.job.name)")
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let p = path {
                Text(p)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var streamPicker: some View {
        Picker("", selection: $stream) {
            Text("stderr").tag(LogStream.stderr)
            Text("stdout").tag(LogStream.stdout)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("stderr/stdout umschalten (w)")
    }

    private var followToggle: some View {
        Toggle(isOn: $vm.followMode) {
            Label("Follow", systemImage: vm.followMode ? "play.fill" : "play")
                .font(.caption.bold())
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help("Log-Follow-Mode (5s auto-refresh)")
    }

    private var copyButton: some View {
        Button {
            if !content.isEmpty { Clipboard.copy(content) }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .slurmyGlassCircleButton()
        .help("Log kopieren")
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .slurmyGlassCircleButton()
        .keyboardShortcut(.cancelAction)
        .help("Schliessen (Esc / Leertaste)")
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(content.isEmpty ? "[\(title) ist (noch) leer]" : content)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
                    .id("logBottom")
            }
            .onChange(of: content) { _, _ in
                if vm.followMode {
                    withMotion(.linear(duration: 0.15)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if vm.followMode {
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
    }
}
