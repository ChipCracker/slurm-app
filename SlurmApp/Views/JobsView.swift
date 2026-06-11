import SwiftUI
#if canImport(AppKit)
import AppKit   // NSCursor for the resizable divider (macOS)
#endif

@MainActor
final class JobsViewModel: ObservableObject {
    /// All jobs (always fetched cluster-wide so GPU allocation is accurate);
    /// the table filters them per the `allUsers` toggle.
    @Published var allJobs: [Job] = []
    @Published var gpuUsage: [PartitionUsage] = []
    @Published var gpuHours: [GpuHoursEntry] = []
    @Published var diskQuotas: [DiskQuota] = []
    @Published var partitionNodes: [String: [PartitionNode]] = [:]
    @Published var partitionDetails: [String: [String: String]] = [:]
    @Published var loading = false
    @Published var error: String?
    @Published var allUsers: Bool = false { didSet { if oldValue != allUsers { recomputeFiltered() } } }
    @Published var runningOnly: Bool = false { didSet { if oldValue != runningOnly { recomputeFiltered() } } }
    @Published var search: String = "" { didSet { if oldValue != search { recomputeFiltered() } } }
    @Published var initialFetchDone: Bool = false

    // MARK: – Derived-row cache (perf)
    // `filtered()` + the filter-bar stats used to be recomputed many times per
    // render and on every keystroke (O(n) each, several passes). They are now
    // computed ONCE whenever an input actually changes and served from a cache.
    struct Stats: Equatable { var running = 0; var pending = 0; var gpus = 0 }
    private(set) var filteredJobs: [Job] = []
    private(set) var stats = Stats()
    /// Bumped on every recompute so the view's `visibleJobs` memo invalidates.
    private(set) var filteredSignature = 0
    private var visibleCacheKey: Int?
    private var visibleCache: [Job] = []
    /// Per-resource in-flight flags so each slow stats card shimmers until ITS
    /// own data lands — the job list (and `initialFetchDone`) finishes much
    /// earlier and must not stop these from showing a loading state.
    @Published var hoursLoading: Bool = true
    @Published var quotasLoading: Bool = true
    private var lastHoursFetch: Date = .distantPast
    private var lastQuotaFetch: Date = .distantPast
    /// GPU hours come from a heavy `sreport` over a year of accounting — they
    /// barely move within half an hour. Auto-refresh at most this often; the
    /// ranking is cached to disk in between (and can be refreshed manually).
    static let hoursRefreshInterval: TimeInterval = 1800   // 30 min

    /// When each partition's nodes/details were last fetched — used to skip a
    /// re-fetch when the same partition is re-opened within `partitionCacheTTL`.
    private var lastPartitionFetch: [String: Date] = [:]
    static let partitionCacheTTL: TimeInterval = 45
    /// Zeitpunkt des letzten erfolgreichen Voll-Refresh. Erlaubt es, beim
    /// Wiederauftauchen der Ansicht (Sektionswechsel) den Cache zu zeigen,
    /// statt erneut per SSH zu laden, solange die Daten frisch sind.
    private(set) var lastFullRefresh: Date = .distantPast
    var isStale: Bool { Date().timeIntervalSince(lastFullRefresh) > 10 }
    /// Zeitpunkt, zu dem die App den Vordergrund verlassen hat (scenePhase
    /// != .active). Ein reiner Sektionswechsel (Settings/Bookmarks) ändert die
    /// scenePhase nicht — die warme SSH-Session bleibt dann unangetastet.
    var leftForegroundAt: Date?
    /// Been away (backgrounded/asleep) long enough that the SSH link probably
    /// died — used to proactively reconnect on foreground instead of hanging on
    /// a half-open socket until the timeout. Based on actual background time,
    /// NOT on data age: merely sitting in another section must not tear down a
    /// healthy session with a full TCP/handshake/auth cycle. (macOS sleep is
    /// additionally covered by AppState's wake observers.)
    var connectionMaybeStale: Bool {
        guard let away = leftForegroundAt else { return false }
        return Date().timeIntervalSince(away) > 30
    }

    // Persistierte UI-Auswahl + Sortierung, damit sie einen Sektionswechsel
    // überleben (JobsView wird dabei neu aufgebaut). Bewusst kein @Published:
    // reines Speichern, das keinen Re-Render auslösen soll.
    var savedCursor: Job.ID?
    var savedMarked: Set<Job.ID> = []
    var savedSortOrder: [KeyPathComparator<Job>]?

    private weak var appState: AppState?
    /// Die persistierten GPU-Stunden-/Quota-Caches werden erst in `bind`
    /// geladen (nicht im init): Erst mit AppState ist der Verbindungs-Scope
    /// (user@host:port) bekannt — Daten eines anderen Clusters/Accounts
    /// dürfen nie als frische Werte erscheinen.
    private var diskCachesLoaded = false

    func bind(_ appState: AppState) {
        self.appState = appState
        recomputeFiltered()   // username now known → keep the filter cache honest
        if !diskCachesLoaded {
            diskCachesLoaded = true
            loadHoursCache()
            loadQuotaCache()
        }
    }

    /// Fetch (and cache) details + node list for one partition. Cheap — used
    /// when the user expands a partition in the Inspector's GPU-allocation
    /// Fetch (and cache) details + node list for one partition. Skips the SSH
    /// round-trip when the same partition was fetched within `partitionCacheTTL`
    /// (re-opening the sheet repeatedly doesn't re-run sinfo each time); the
    /// sheet's refresh button passes `force: true` for live node states.
    func loadPartition(_ name: String, force: Bool = false) async {
        guard let slurm = appState?.slurm else { return }
        if !force,
           partitionNodes[name] != nil,
           let last = lastPartitionFetch[name],
           Date().timeIntervalSince(last) < Self.partitionCacheTTL {
            return   // fresh enough — serve cache
        }
        async let d: [String: String]? = try? await slurm.fetchPartitionDetails(name)
        async let n: [PartitionNode]?  = try? await slurm.fetchPartitionNodes(name)
        if let nodes = await n  { self.partitionNodes[name] = nodes }
        if let det   = await d  { self.partitionDetails[name] = det }
        lastPartitionFetch[name] = Date()
    }

    /// Jobs after applying only the user filter (allUsers). Drives the
    /// filter-bar stats. Cheap recompute keeps this honest.
    var jobs: [Job] {
        guard let me = appState?.credentials?.username, !allUsers else { return allJobs }
        return allJobs.filter { $0.user == me }
    }

    /// Cached filtered list (user + runningOnly + search). Recomputed only when
    /// an input changes, not per render/keystroke.
    func filtered() -> [Job] { filteredJobs }

    /// Recompute the cached filtered list and stats. Call when allJobs or the
    /// username changes (the filter toggles trigger it via their didSet).
    func recomputeFiltered() {
        let me = appState?.credentials?.username
        let base = (allUsers || me == nil) ? allJobs : allJobs.filter { $0.user == me }

        var s = Stats()
        for j in base {
            if j.isRunning { s.running += 1; s.gpus += j.gpus }
            else if j.isPending { s.pending += 1 }
        }
        stats = s

        var result = base
        if runningOnly { result = result.filter(\.isRunning) }
        if !search.isEmpty {
            // Lowercase the query once and match against lowered fields instead
            // of 5× localizedCaseInsensitiveContains per job.
            let q = search.lowercased()
            result = result.filter { j in
                j.jobId.lowercased().contains(q) || j.name.lowercased().contains(q) ||
                j.user.lowercased().contains(q) || j.partition.lowercased().contains(q) ||
                j.state.lowercased().contains(q)
            }
        }
        filteredJobs = result
        filteredSignature &+= 1
        visibleCacheKey = nil   // invalidate the sort memo
    }

    /// Sorted + running-first-partitioned visible rows, memoized so the table,
    /// height calc, cursor math and stats don't each re-sort within one render.
    func visibleJobs(sortOrder: [KeyPathComparator<Job>], runningFirst: Bool) -> [Job] {
        var hasher = Hasher()
        hasher.combine(filteredSignature)
        hasher.combine(runningFirst)
        for c in sortOrder { hasher.combine(c.keyPath); hasher.combine(c.order) }
        let key = hasher.finalize()
        if key == visibleCacheKey { return visibleCache }
        var sorted = filteredJobs.sorted(using: sortOrder)
        if runningFirst { sorted = sorted.filter(\.isRunning) + sorted.filter { !$0.isRunning } }
        visibleCacheKey = key
        visibleCache = sorted
        return sorted
    }

    // MARK: – Spaltenbreiten-Memo (perf)
    // `ColumnSizing` lief früher bei JEDEM Body-Durchlauf über alle sichtbaren
    // Zeilen (≈12 O(n)-String-Pässe pro Tastendruck/Cursor-Schritt). Die
    // Breiten hängen nur von der gefilterten Menge (Sortierung ändert sie
    // nicht) und den Zeichenbreiten-Metriken ab → Memo über filteredSignature.
    private var sizingCacheKey: Int?
    private var sizingCache: ColumnSizing?

    fileprivate func columnSizing(skeleton: [Job], propPx: CGFloat, monoPx: CGFloat) -> ColumnSizing {
        var hasher = Hasher()
        hasher.combine(filteredJobs.isEmpty ? -1 : filteredSignature)
        hasher.combine(propPx)
        hasher.combine(monoPx)
        let key = hasher.finalize()
        if key == sizingCacheKey, let cached = sizingCache { return cached }
        let sizing = ColumnSizing(
            jobs: filteredJobs.isEmpty ? skeleton : filteredJobs,
            propPx: propPx, monoPx: monoPx
        )
        sizingCacheKey = key
        sizingCache = sizing
        return sizing
    }

    /// Guards against overlapping refreshes (the initial `.task`, the scenePhase
    /// catch-up and a manual refresh can all fire on section re-entry — without
    /// this they enqueued duplicate squeue/sreport/quota fetches).
    private var refreshing = false
    /// Partition GPU totals are cluster-static; cache them so the 10s poll
    /// doesn't re-run `sinfo -N` every tick (only `squeue` actually changes).
    private var cachedParts: [PartitionGpu] = []
    private var lastPartsFetch: Date = .distantPast
    static let partsRefreshInterval: TimeInterval = 300   // 5 min

    /// `silent` (used by the 10s poll) skips the `loading` toggle so a background
    /// tick doesn't trigger two extra full-body passes nothing displays.
    func refresh(silent: Bool = false) async {
        guard let slurm = appState?.slurm else { return }
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let me = appState?.credentials?.username ?? ""
        if !silent { loading = true }
        defer { if !silent { loading = false } }
        // Nur der stille 10s-Hintergrund-Tick ist ein Poll — alle Nutzer-Pfade
        // (Toolbar-Refresh, Pull-to-Refresh, Post-Action-Refresh) rufen
        // silent=false und springen in der SSH-Queue vor wartende Poll-Ticks.
        let priority: SSHCommandPriority = silent ? .poll : .userInitiated
        do {
            let jobsList = try await slurm.fetchJobs(allUsers: true, currentUser: "", priority: priority)
            // Refetch the static partition GRES at most every 5 min, not per tick.
            let parts: [PartitionGpu]
            if cachedParts.isEmpty || Date().timeIntervalSince(lastPartsFetch) > Self.partsRefreshInterval {
                parts = try await slurm.fetchPartitionGpus(priority: priority)
                cachedParts = parts
                lastPartsFetch = Date()
            } else {
                parts = cachedParts
            }
            // Publish only on real change — on a quiet cluster the output is
            // usually identical, so this avoids a full JobsView re-render cascade
            // every tick. Job/PartitionUsage are Equatable.
            if jobsList != allJobs {
                allJobs = jobsList
                recomputeFiltered()
            }
            let usage = SlurmParser
                .computeUsage(jobs: jobsList, partitions: parts, currentUser: me)
                .sorted { $0.partition < $1.partition }
            if usage != gpuUsage { gpuUsage = usage }
            if error != nil { error = nil }
            lastFullRefresh = Date()
            appState?.reportConnectionHealthy()
        } catch {
            // Strukturierte Cancellation (Sektionswechsel, scenePhase-Flip via
            // Cmd-Tab/Minimieren) ist KEIN Verbindungsfehler: Die SSH-Schicht
            // wirft jetzt CancellationError für abgebrochene Tasks — weder das
            // englische System-Banner zeigen noch den Status auf „instabil"
            // degradieren. Early return ist sicher: Die defers setzen
            // refreshing/loading zurück, alles danach ist für einen
            // abgebrochenen Tick irrelevant.
            if error is CancellationError || Task.isCancelled { return }
            self.error = error.localizedDescription
            appState?.reportConnectionTrouble(error.localizedDescription)
        }

        // Jobs + partitions are in → stop the table skeleton NOW, before the
        // slow cluster stats below. Otherwise an empty own-job list (or a slow
        // `sreport`) would keep the job list shimmering "forever" on first open.
        // The inspector's GPU-hours/quota cards have their own loading states,
        // so they can finish independently. No `withAnimation` here — that would
        // leak the transaction into the detail pane and re-fire its load anim.
        if !initialFetchDone {
            initialFetchDone = true
        }

        // Slow cluster stats — independent cadences and their own loading flags
        // so each card shimmers until ITS data lands. GPU hours barely change,
        // so they ride a long (30 min) cache window; disk quotas move faster.
        let now = Date()
        if gpuHours.isEmpty || now.timeIntervalSince(lastHoursFetch) > Self.hoursRefreshInterval {
            await reloadGpuHours()
        }
        if diskQuotas.isEmpty || now.timeIntervalSince(lastQuotaFetch) > 300 {
            await reloadDiskQuotas()
        }
    }

    /// (Re)load the GPU-hours ranking and refresh the on-disk cache. Called on
    /// the 30-min cadence from `refresh()` and by the card's manual refresh
    /// button (`force: true` erzwingt einen frischen `sreport`).
    ///
    /// Teilt sich den verbindungsgebundenen Cache mit dem GPU-Hours-Sheet
    /// (AppState, Key „thisYear"): Beide Oberflächen zeigen denselben
    /// Jahres-`sreport` — wer zuerst lädt, bedient den anderen, statt das
    /// schwerste Read-Kommando der App doppelt auf die serielle SSH-Queue
    /// zu legen (und für denselben Zeitraum abweichende Ranglisten zu zeigen).
    func reloadGpuHours(force: Bool = false) async {
        guard let slurm = appState?.slurm else { return }
        let cacheKey = RangePreset.thisYear.rawValue
        if !force,
           let cached = appState?.cachedGpuHoursEntry(forKey: cacheKey),
           Date().timeIntervalSince(cached.at) < Self.hoursRefreshInterval {
            gpuHours = Array(cached.entries.prefix(10))
            lastHoursFetch = cached.at
            hoursLoading = false
            persistHoursCache()
            return
        }
        hoursLoading = true
        defer { hoursLoading = false }
        // Volle Liste holen (`topN` wird ohnehin client-seitig angewendet),
        // damit der geteilte Cache auch das Sheet (alle Nutzer + Suche)
        // bedienen kann; die Card zeigt weiterhin die Top 10.
        if let hours = try? await slurm.fetchGpuHours(topN: 0) {
            self.gpuHours = Array(hours.prefix(10))
            self.lastHoursFetch = Date()
            persistHoursCache()
            appState?.storeGpuHours(hours, forKey: cacheKey)
        }
    }

    /// (Re)load disk quotas. Cheaper than sreport; 5-min cadence from
    /// `refresh()`, or on demand.
    func reloadDiskQuotas() async {
        guard let slurm = appState?.slurm else { return }
        quotasLoading = true
        defer { quotasLoading = false }
        if let q = try? await slurm.fetchDiskQuotas() {
            self.diskQuotas = q
            self.lastQuotaFetch = Date()
            persistQuotaCache()
        }
    }

    // MARK: – GPU-hours disk cache (survives app restarts so the 30-min window
    // is honoured across launches instead of re-running sreport every time).

    private static let hoursCacheKey = "gpuHoursCache.v1"

    private struct HoursCache: Codable {
        let entries: [GpuHoursEntry]
        let fetchedAt: Date
        /// Verbindungs-Scope (user@host:port) — ein nach Cluster-/Account-
        /// Wechsel geladener Cache eines anderen Clusters wird verworfen.
        /// Alte Payloads ohne `scope` scheitern am Decode und werden ebenso
        /// verworfen (gewollte Migration).
        let scope: String
    }

    private func loadHoursCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.hoursCacheKey),
              let cache = try? JSONDecoder().decode(HoursCache.self, from: data),
              cache.scope == appState?.connectionCacheScope,
              !cache.entries.isEmpty else { return }
        gpuHours = cache.entries
        lastHoursFetch = cache.fetchedAt
        hoursLoading = false   // show cached data immediately, no shimmer
    }

    private func persistHoursCache() {
        guard let scope = appState?.connectionCacheScope else { return }
        let cache = HoursCache(entries: gpuHours, fetchedAt: lastHoursFetch, scope: scope)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.hoursCacheKey)
        }
    }

    // MARK: – Disk-quota disk cache (survives restarts; 5-min window honoured
    // across launches instead of re-running the quota command every time).

    private static let quotaCacheKey = "diskQuotaCache.v1"

    private struct QuotaCache: Codable {
        let quotas: [DiskQuota]
        let fetchedAt: Date
        /// Siehe HoursCache.scope — bindet den Cache an die Verbindung.
        let scope: String
    }

    private func loadQuotaCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.quotaCacheKey),
              let cache = try? JSONDecoder().decode(QuotaCache.self, from: data),
              cache.scope == appState?.connectionCacheScope,
              !cache.quotas.isEmpty else { return }
        diskQuotas = cache.quotas
        lastQuotaFetch = cache.fetchedAt
        quotasLoading = false
    }

    private func persistQuotaCache() {
        guard let scope = appState?.connectionCacheScope else { return }
        let cache = QuotaCache(quotas: diskQuotas, fetchedAt: lastQuotaFetch, scope: scope)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.quotaCacheKey)
        }
    }

    #if DEBUG
    /// Statische Mock-Daten zum Layout-Testen ohne SSH (via `SLURMIOS_UIMOCK=1`).
    @discardableResult
    func loadMockIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["SLURMIOS_UIMOCK"] == "1" else { return false }
        allJobs = Self.mockJobs
        recomputeFiltered()
        gpuUsage = Self.mockUsage
        gpuHours = Self.mockGpuHours
        diskQuotas = Self.mockDiskQuotas
        initialFetchDone = true
        hoursLoading = false
        quotasLoading = false
        return true
    }

    private static let mockGpuHours: [GpuHoursEntry] = [
        GpuHoursEntry(user: "beckerlu", hours: 5240),
        GpuHoursEntry(user: "witzlch88229", hours: 4820),
        GpuHoursEntry(user: "schmidtka", hours: 3110),
        GpuHoursEntry(user: "muellerth", hours: 1890),
        GpuHoursEntry(user: "wagnerfe", hours: 1240),
        GpuHoursEntry(user: "kleinmar", hours: 760),
    ]

    private static let mockDiskQuotas: [DiskQuota] = [
        DiskQuota(filesystem: "/home", used: "9847M", quota: "20480M", limit: "22528M",
                  usedBytes: 9847 * 1024 * 1024, quotaBytes: 20480 * 1024 * 1024),
        DiskQuota(filesystem: "/scratch", used: "412G", quota: "500G", limit: "550G",
                  usedBytes: 412 * 1024 * 1024 * 1024, quotaBytes: 500 * 1024 * 1024 * 1024),
    ]

    private static let mockJobs: [Job] = [
        Job(jobId: "184523", name: "train_resnet50_imagenet", user: "witzlch88229", state: "R",
            partition: "gpu", qos: "normal", gpus: 4, cpus: 16, memory: "64G",
            runtime: "2:14:05", node: "node07", reason: ""),
        Job(jobId: "184524", name: "eval_sweep_lr_0.001_bs256", user: "witzlch88229", state: "R",
            partition: "gpu", qos: "high", gpus: 1, cpus: 8, memory: "32G",
            runtime: "0:42:18", node: "node03", reason: ""),
        Job(jobId: "184530", name: "preprocess_dataset", user: "muellerth", state: "R",
            partition: "cpu", qos: "normal", gpus: 0, cpus: 32, memory: "128G",
            runtime: "5:03:51", node: "node11", reason: ""),
        Job(jobId: "184601", name: "hyperparam_search_very_long_experiment_name", user: "witzlch88229",
            state: "PD", partition: "gpu", qos: "normal", gpus: 8, cpus: 32, memory: "256G",
            runtime: "0:00", node: "", reason: "Resources"),
        Job(jobId: "184602", name: "finetune_llm", user: "schmidtka", state: "PD",
            partition: "gpu", qos: "low", gpus: 2, cpus: 12, memory: "48G",
            runtime: "0:00", node: "", reason: "Priority"),
        Job(jobId: "184488", name: "nightly_backup", user: "muellerth", state: "R",
            partition: "cpu", qos: "normal", gpus: 0, cpus: 4, memory: "8G",
            runtime: "11:58:22", node: "node01", reason: ""),
        Job(jobId: "184610", name: "inference_batch", user: "witzlch88229", state: "CG",
            partition: "gpu", qos: "normal", gpus: 1, cpus: 8, memory: "16G",
            runtime: "1:22:40", node: "node05", reason: ""),
        Job(jobId: "184611", name: "diffusion_train_v3", user: "beckerlu", state: "R",
            partition: "gpu", qos: "high", gpus: 4, cpus: 24, memory: "96G",
            runtime: "8:17:09", node: "node09", reason: ""),
        Job(jobId: "184620", name: "data_aug_pipeline", user: "schmidtka", state: "PD",
            partition: "cpu", qos: "normal", gpus: 0, cpus: 16, memory: "32G",
            runtime: "0:00", node: "", reason: "Dependency"),
        Job(jobId: "184477", name: "tensorboard_logserver", user: "witzlch88229", state: "R",
            partition: "interactive", qos: "normal", gpus: 0, cpus: 2, memory: "4G",
            runtime: "1-03:44:12", node: "node02", reason: ""),
    ]

    private static let mockUsage: [PartitionUsage] = [
        PartitionUsage(partition: "gpu", gpuType: "A100", totalGpus: 32,
                       ownNonPreemptible: 5, ownPreemptible: 0, otherNonPreemptible: 18, otherPreemptible: 4),
        PartitionUsage(partition: "gpu-large", gpuType: "H100", totalGpus: 16,
                       ownNonPreemptible: 0, ownPreemptible: 0, otherNonPreemptible: 10, otherPreemptible: 2),
        PartitionUsage(partition: "dev", gpuType: "A40", totalGpus: 8,
                       ownNonPreemptible: 1, ownPreemptible: 0, otherNonPreemptible: 2, otherPreemptible: 0),
    ]
    #endif
}

struct JobsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bookmarks: BookmarksStore
    @EnvironmentObject var dashboard: DashboardStore
    /// In `MainTabView` erzeugt und injiziert, damit Daten + Lade-Status einen
    /// Sektionswechsel überleben (sonst Neuaufbau → SSH-Neuladen).
    @EnvironmentObject var vm: JobsViewModel
    /// Konfigurierbares Grid-Dashboard statt der klassischen Ansicht.
    /// macOS: Alternative zum Split-View. iPad (regular width): Alternative zur
    /// gepushten Detail-Navigation. iPhone (compact): ignoriert (feste Liste).
    @AppStorage("jobsDashboardEnabled") private var dashboardEnabled = false
    /// Edit-Modus: Widgets verschieben/skalieren.
    @State private var editingDashboard = false
    /// Laufende Jobs immer oben einsortieren (unabhängig von der Spaltensortierung).
    @AppStorage("runningJobsFirst") private var runningJobsFirst = false
    /// Einmalige Wiederherstellung von Auswahl/Sortierung pro View-Instanz.
    @State private var didRestore = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var sortOrder: [KeyPathComparator<Job>] = [
        .init(\.jobId, order: .reverse)
    ]
    /// Cursor in the Table — moves with ↑/↓.
    @State private var cursor: Job.ID? = nil
    /// Multi-selection set built up via Space (TUI-style).
    /// `⌘A` selects all visible rows, Esc clears it.
    @State private var marked: Set<Job.ID> = []
    @State private var showSubmit = false
    @State private var showInteractive = false
    @State private var sheetPartition: PartitionSelection?
    @State private var showGpuHoursSheet: Bool = false
    @State private var showNodesSheet: Bool = false
    @State private var showHelp: Bool = false
    /// Full-size log modal raised from the detail pane (click or Space).
    /// Holds the live JobDetailViewModel so it streams in Follow-mode.
    @State private var logModal: LogModalSelection? = nil
    @State private var cancelConfirmJobs: [Job] = []
    // Batch-Aktionen auf der markierten Menge (wie slurm-tui)
    @State private var batchValueAction: BatchAction?      // qos/partition → Werte-Sheet
    @State private var batchConfirm: BatchConfirmation?    // cancel/hold/release/requeue → Dialog
    @State private var batchResult: String?                // Ergebnis-Alert
    @State private var availableQos: [String] = []
    @State private var availablePartitions: [String] = []
    #if os(iOS)
    @State private var selectionMode = false               // iOS Auswahl-Modus
    #endif
    /// +1 = last move was downward, -1 = upward. Space-mark and other
    /// auto-advance actions use this so they keep walking in the user's
    /// current direction instead of always going down.
    @State private var lastDirection: Int = 1
    @FocusState private var focusedPane: Pane?
    /// Fokus-Binding des Suchfelds — Ziel des ⌘F-Shortcuts (`Shortcut.focusSearch`)
    /// und Wächter, damit ⌘A im Suchfeld das normale „Alles auswählen" bleibt.
    @FocusState private var searchFocused: Bool
    #if os(iOS)
    /// Snapshot des gepushten Jobs: bleibt erhalten, wenn der Job aus der
    /// squeue-Ausgabe altert, damit das Detail (letzte Logs!) nicht mitten im
    /// Lesen wegpoppt. Erst das Zurück-Navigieren räumt ihn auf.
    @State private var presentedJob: Job? = nil
    #endif
    /// Zeichenbreiten-Schätzungen / Zeilenmaße für Tabelle und Höhen-Schätzung
    /// — skalieren über @ScaledMetric mit der Textgröße (⌘+/⌘-), sonst
    /// trunkieren die Spalten bei großen Stufen an eingefrorenen Pixelbreiten.
    @ScaledMetric(relativeTo: .callout) private var propPx: CGFloat = 6.5   // SF Pro Text @ .callout
    @ScaledMetric(relativeTo: .callout) private var monoPx: CGFloat = 7.6   // SF Mono @ .callout
    @ScaledMetric(relativeTo: .callout) private var tableRowH: CGFloat = 20
    @ScaledMetric(relativeTo: .callout) private var tableHeaderH: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var filterBarH: CGFloat = 42
    @AppStorage("inspectorOpen") private var inspectorOpen: Bool = true
    /// iOS: Cluster-Inspector als Sheet, startet geschlossen (entkoppelt vom
    /// persistierten macOS-Pane-Zustand `inspectorOpen`). Auf macOS ungenutzt.
    @State private var showInspectorSheet = false

    /// One of the four navigable regions inside the Jobs section.
    /// `Tab` / `⇧Tab` cycles between them; arrow keys then operate inside
    /// whichever pane currently holds focus.
    enum Pane: Hashable, CaseIterable {
        case sidebar, table, detail, inspector
    }

    /// Items the Inspector cursor can sit on. Disk-Quotas has no modal
    /// trigger and is therefore not part of the traversal.
    enum InspectorCursor: Hashable {
        case partition(String)
        case gpuHours
    }
    @State private var inspectorCursor: InspectorCursor? = nil

    /// Snapshot of focus + inspector cursor taken when the first modal of
    /// a stack opens. Restored when all modals close, so Space-from-Inspector
    /// returns to the same pill instead of dropping back to the table.
    @State private var paneBeforeModal: Pane? = nil
    @State private var inspectorCursorBeforeModal: InspectorCursor? = nil

    var body: some View {
        paneLayout
        .sheet(isPresented: $showSubmit) {
            SubmitJobView().environmentObject(appState)
        }
        .sheet(isPresented: $showInteractive) {
            InteractiveSessionView().environmentObject(appState)
        }
        #if os(iOS)
        // iOS: Cluster-Inspector als Sheet. Die Partition-/GPU-Hours-Sheets
        // werden HIER am Sheet-Inhalt aufgehängt (nicht am Body), damit sie
        // ÜBER dem Cluster-Sheet erscheinen, wenn man darin ein Element antippt
        // — vom dahinterliegenden Body aus könnte iOS kein Sheet präsentieren.
        .sheet(isPresented: $showInspectorSheet) {
            NavigationStack {
                inspectorPane
                    .navigationTitle("Cluster")
                    .inlineNavTitle()
                    // Kein opaker Nav-Bar-Hintergrund — System-Bar = Liquid Glass.
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .glassModal(item: $sheetPartition) { partitionSheet($0) }
            .glassModal(isPresented: $showGpuHoursSheet) { gpuHoursSheet }
        }
        .glassModal(isPresented: $showNodesSheet) { nodesSheet }
        // iPad-Dashboard hat KEIN Inspector-Sheet, das die Partition-/GPU-Hours-
        // Sheets hostet — dort würden Taps auf Dashboard-Widgets ins Leere laufen.
        // Im Dashboard-Modus daher direkt am Body präsentieren; die Bindings sind
        // außerhalb des Dashboards inert, sodass die Inspector-Variante oben
        // (für den gestapelten Fall) ungestört bleibt.
        .glassModal(item: dashboardPartitionBinding) { partitionSheet($0) }
        .glassModal(isPresented: dashboardGpuHoursBinding) { gpuHoursSheet }
        #else
        .glassModal(item: $sheetPartition) { partitionSheet($0) }
        .glassModal(isPresented: $showGpuHoursSheet) { gpuHoursSheet }
        .glassModal(isPresented: $showNodesSheet) { nodesSheet }
        #endif
        .glassModal(isPresented: $showHelp, maxWidth: .infinity, maxHeight: .infinity) {
            HelpOverlayView()
        }
        .glassModal(item: $logModal) { sel in
            LogDetailSheetView(vm: sel.vm, stream: sel.stream)
        }
        .background(hiddenShortcuts)
        .background(paneCycleShortcuts)
        #if os(iOS)
        // Haptic feedback for touch interactions (no-op on Mac).
        .sensoryFeedback(.selection, trigger: marked)
        .sensoryFeedback(.success, trigger: batchResult)
        #endif
        .confirmationDialog(
            cancelConfirmJobs.count == 1
                ? "Job \(cancelConfirmJobs.first?.jobId ?? "") beenden?"
                : "\(cancelConfirmJobs.count) Jobs beenden?",
            isPresented: Binding(
                get: { !cancelConfirmJobs.isEmpty },
                set: { if !$0 { cancelConfirmJobs = [] } }
            ),
            // iOS blendet den Titel per Default aus — der Job-/Zähler-Kontext
            // muss aber immer sichtbar sein.
            titleVisibility: .visible
        ) {
            Button("Job beenden", role: .destructive) {
                let jobs = cancelConfirmJobs
                cancelConfirmJobs = []
                Task {
                    do {
                        // One scancel for the whole set instead of N round-trips.
                        try await appState.slurm?.cancelJobs(jobs.map(\.jobId))
                    } catch {
                        // Surface the real error (stderr now reaches us) instead
                        // of silently doing nothing.
                        batchResult = "scancel fehlgeschlagen: \(error.localizedDescription)"
                    }
                    await vm.refresh()   // reflect the change in the list
                }
            }
            Button("Behalten", role: .cancel) { cancelConfirmJobs = [] }
        }
        // Batch: Werte-Sheet (QoS/Partition)
        .sheet(item: $batchValueAction) { action in
            BatchValueSheet(
                action: action,
                jobCount: eligible(action).count,
                options: action == .qos ? availableQos : availablePartitions,
                onApply: { value in applyBatch(action, to: eligible(action), value: value) }
            )
        }
        // Batch: Bestätigung (Cancel/Hold/Release/Requeue)
        .confirmationDialog(
            batchConfirm.map { "\($0.jobs.count) Job\($0.jobs.count == 1 ? "" : "s") \($0.action.confirmVerb)?" } ?? "",
            isPresented: Binding(get: { batchConfirm != nil }, set: { if !$0 { batchConfirm = nil } }),
            // Titel (mit Job-Anzahl) auch auf iOS immer zeigen — sonst stünde
            // der destruktive Button ohne jeden Kontext da.
            titleVisibility: .visible,
            presenting: batchConfirm
        ) { c in
            // Destruktiv mit eindeutigem Verb-Objekt-Label, damit neben dem
            // Dismiss-„Abbrechen" nie ein zweites „Abbrechen" steht.
            Button(
                c.action == .cancel
                    ? "\(c.jobs.count) Job\(c.jobs.count == 1 ? "" : "s") beenden"
                    : c.action.title,
                role: c.action.isDestructive ? .destructive : nil
            ) {
                applyBatch(c.action, to: c.jobs)
            }
            Button("Abbrechen", role: .cancel) {}
        }
        // Batch: Ergebnis
        .alert(
            "Batch-Ergebnis",
            isPresented: Binding(get: { batchResult != nil }, set: { if !$0 { batchResult = nil } }),
            presenting: batchResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .task {
            #if DEBUG
            if vm.loadMockIfRequested() {
                // Deep-Link für Layout-Screenshots: SLURMIOS_UIMOCK_OPEN=detail|inspector|submit|interactive
                switch ProcessInfo.processInfo.environment["SLURMIOS_UIMOCK_OPEN"] {
                case "detail":      cursor = vm.allJobs.first?.id
                case "inspector":   showInspectorSheet = true
                case "submit":      showSubmit = true
                case "interactive": showInteractive = true
                case "partition":
                    showInspectorSheet = true
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    sheetPartition = vm.gpuUsage.first.map { PartitionSelection(name: $0.partition) }
                #if os(iOS)
                case "select":
                    selectionMode = true
                    marked = Set(vm.allJobs.prefix(5).map(\.id))
                case "batchqos":
                    selectionMode = true
                    marked = Set(vm.allJobs.prefix(5).map(\.id))
                    availableQos = ["normal", "high", "low", "interactive"]
                    availablePartitions = ["gpu", "gpu-large", "dev", "cpu"]
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    batchValueAction = .qos
                #endif
                default: break
                }
                return
            }
            #endif
            vm.bind(appState)
            // Beim (erneuten) Erscheinen nur laden, wenn noch nie geladen wurde
            // oder die Daten veraltet sind — sonst zeigt die Tabelle sofort den
            // Cache. Das Polling läuft in der scenePhase-Task unten.
            if !vm.initialFetchDone || vm.isStale {
                await vm.refresh()
            }
            // Auto-focus the table so arrow keys work from the first frame.
            focusedPane = .table
        }
        // Poll squeue/sinfo every 10s — but ONLY while the window is in the
        // foreground. Keyed on scenePhase: leaving the foreground cancels the
        // loop (no SSH while hidden/inactive), returning restarts it with an
        // immediate catch-up refresh if the cache went stale.
        .task(id: scenePhase) {
            vm.bind(appState)
            guard scenePhase == .active else {
                // Vordergrund verlassen → frühesten Zeitpunkt merken. Nur echte
                // Hintergrund-/Schlafzeit zählt als „Link vermutlich tot" —
                // ein Sektionswechsel feuert hier nie (scenePhase bleibt aktiv).
                if vm.leftForegroundAt == nil { vm.leftForegroundAt = Date() }
                return
            }
            // Returned to the foreground after a while → the SSH link may be
            // dead. Rebuild it first so the catch-up refresh is instant instead
            // of blocking on a half-open socket until the 45s timeout.
            if vm.initialFetchDone && vm.connectionMaybeStale {
                await appState.slurm?.reconnect()
            }
            vm.leftForegroundAt = nil
            if vm.initialFetchDone && vm.isStale { await vm.refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                if Task.isCancelled { break }
                await vm.refresh(silent: true)   // background tick: no loading flash
            }
        }
        // Jump to a job (from a bookmark tap): select it if present, else seed
        // the search so the user can see why it's gone.
        .onReceive(NotificationCenter.default.publisher(for: .openJob)) { note in
            guard let jid = note.object as? String else { return }
            if vm.allJobs.contains(where: { $0.id == jid }) {
                cursor = jid
            } else {
                vm.search = jid
            }
        }
        .onChange(of: anyModalOpen) { _, open in
            if open {
                // Capture the focus context once per modal stack, so a
                // second modal layered on top doesn't overwrite the
                // originally-focused pane.
                if paneBeforeModal == nil {
                    paneBeforeModal = focusedPane
                    inspectorCursorBeforeModal = inspectorCursor
                }
            } else {
                let restorePane = paneBeforeModal ?? .table
                let restoreCursor = inspectorCursorBeforeModal
                paneBeforeModal = nil
                inspectorCursorBeforeModal = nil
                // Seed the cursor before flipping focus so the
                // focusedPane-onChange handler sees a non-nil value and
                // doesn't reseed it to the first item.
                if restorePane == .inspector, let c = restoreCursor {
                    inspectorCursor = c
                }
                focusedPane = restorePane
            }
        }
        .onChange(of: focusedPane) { _, pane in
            // Seed the inspector cursor on entry; clear it on exit so the
            // next visit always lands on the first item. Dedup so we don't
            // re-publish the same value (would cascade into a redundant
            // body re-render).
            let next: InspectorCursor? = (pane == .inspector)
                ? (inspectorCursor ?? firstInspectorItem())
                : nil
            if next != inspectorCursor { inspectorCursor = next }
        }
        .onChange(of: vm.gpuUsage) { _, _ in
            // If the partition list reloads and the focused partition is
            // gone, reseed the cursor.
            if focusedPane == .inspector,
               case .partition(let n) = inspectorCursor,
               !vm.gpuUsage.contains(where: { $0.partition == n }) {
                inspectorCursor = firstInspectorItem()
            }
        }
        .onChange(of: cursor) { oldValue, newValue in
            // Auswahl für den nächsten Ansichtswechsel merken.
            vm.savedCursor = newValue
            #if os(iOS)
            // Snapshot des (per Cursor) gepushten Jobs aktualisieren — er hält
            // das Detail offen, falls der Job später aus der Queue altert.
            if let id = newValue, let live = vm.allJobs.first(where: { $0.id == id }) {
                presentedJob = live
            }
            #endif
            // A log modal belongs to one job's detail pane — if the selection
            // moves (or clears), drop it so it can't show a stale job's log.
            if oldValue != newValue, logModal != nil { logModal = nil }
            // Track direction of the latest navigation step so Space-mark
            // and any future auto-advance respect what the user just did.
            guard let old = oldValue, let new = newValue, old != new else { return }
            let rows = visibleJobs
            if let oi = rows.firstIndex(where: { $0.id == old }),
               let ni = rows.firstIndex(where: { $0.id == new }) {
                if ni > oi { lastDirection = +1 }
                else if ni < oi { lastDirection = -1 }
            }
        }
        .onChange(of: vm.allJobs) { _, newJobs in
            let alive = Set(newJobs.map(\.id))
            marked = marked.intersection(alive)
            #if os(iOS)
            // Solange der gepushte Job noch in der Queue ist, den Snapshot
            // mit den Live-Daten nachführen (Status/Laufzeit im Detail-Kopf).
            if let p = presentedJob, let live = newJobs.first(where: { $0.id == p.id }) {
                presentedJob = live
            }
            #endif
            if let c = cursor, !alive.contains(c) {
                // The selected job left the queue — clear the selection but do
                // NOT yank the cursor to row 0 mid-read (that jumped to an
                // unrelated job on macOS). On iOS `presentedJob` keeps the
                // pushed detail alive, so clearing the cursor no longer pops it.
                cursor = nil
            } else {
                ensureCursor()
            }
        }
        // Prune marks to what's actually visible when a filter changes, so the
        // marked count and bulk actions never include rows the user can't see.
        .onChange(of: vm.runningOnly) { _, _ in pruneMarkedToVisible(); ensureCursor() }
        .onChange(of: vm.allUsers)    { _, _ in pruneMarkedToVisible(); ensureCursor() }
        .onChange(of: vm.search)      { _, _ in pruneMarkedToVisible(); ensureCursor() }
        .onChange(of: marked)         { _, m in vm.savedMarked = m }
        .onChange(of: sortOrder)      { _, s in vm.savedSortOrder = s }
        .onAppear { restoreSelection() }
    }

    /// Stellt Auswahl + Sortierung aus dem persistenten ViewModel wieder her —
    /// einmal pro View-Instanz, damit ein Sektionswechsel den Zustand behält.
    private func restoreSelection() {
        guard !didRestore else { return }
        didRestore = true
        if !vm.savedMarked.isEmpty { marked = vm.savedMarked }
        if let s = vm.savedSortOrder { sortOrder = s }
        #if os(macOS)
        // Cursor nur auf macOS wiederherstellen — auf iOS würde ein gesetzter
        // Cursor sofort die Detail-Navigation pushen.
        if let c = vm.savedCursor { cursor = c }
        #endif
    }

    /// Scrollt die Tabelle zur aktuell gewählten Zeile (Scroll-Zustand nach
    /// Ansichtswechsel). Kleiner Aufschub, damit die Zeilen schon stehen.
    private func scrollToCursor(_ proxy: ScrollViewProxy) {
        guard let id = cursor else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: – Plattform-Layout

    /// macOS: drei-spaltiges `HSplitView` (Tabelle | Detail | Inspector).
    /// iOS: `NavigationStack` mit Tabelle als Wurzel; Detail wird gepusht,
    /// der Cluster-Inspector läuft als Sheet (siehe Body).
    @ViewBuilder
    private var paneLayout: some View {
        #if os(macOS)
        Group {
            if dashboardEnabled {
                dashboardLayout
            } else {
                splitLayout
            }
        }
        .slurmyContentBackground()
        .toolbar { jobsToolbar }
        .searchable(text: $vm.search, prompt: "Suche Job, User, Partition, Status")
        .searchFocusedCompat($searchFocused)   // ⌘F (Shortcut.focusSearch) springt hierhin
        #else
        NavigationStack {
            Group {
                // iPad (regular width) + Dashboard: das Grid ersetzt die
                // gepushte Detail-Navigation — das Detail ist ein eigenes Widget.
                if iPadDashboardActive {
                    dashboardLayout
                } else {
                    leadingPane
                }
            }
                .slurmyContentBackground()
                .navigationTitle("Jobs")
                .inlineNavTitle()
                // Keine opaken Nav-Bar-Hintergründe mehr: Die System-Bars
                // adoptieren auf iOS 26 automatisch Liquid Glass und sampeln
                // den Theme-Content darunter.
                .navigationDestination(isPresented: iosDetailPresented) {
                    detailPane
                        .environmentObject(appState)
                }
                .toolbar { jobsToolbar }
                // Im Auswahl-Modus die Tab-Leiste ausblenden, damit die untere
                // Aktionsleiste freisteht (iOS-Standard wie Mail/Fotos).
                .toolbar(selectionMode ? .hidden : .automatic, for: .tabBar)
                .searchable(text: $vm.search, prompt: "Suche Job, User, Partition, Status")
                .searchFocusedCompat($searchFocused)   // ⌘F (Hardware-Tastatur)
        }
        #endif
    }

    #if os(macOS)
    /// Klassische Drei-Spalten-Ansicht (Tabelle | Detail | Inspector) mit
    /// ziehbaren Trennern — der bewährte Default ohne Grid-Engine.
    private var splitLayout: some View {
        // The panes are built here ONCE per render and handed to the split
        // containers as values; the containers own the divider state, so a drag
        // re-applies frames without rebuilding the (heavy) jobs Table. See
        // ResizableSplits.swift.
        ResizableHSplit2(showRight: inspectorOpen, defaultRight: 380, minLeft: 460) {
            ResizableVSplit2(
                autoTopHeight: tableContentHeight(rows: vm.filtered().count),
                minTop: Self.leftMinTop,
                minBottom: Self.leftMinBottom
            ) {
                leadingPane
                    .paneFocusRing(focusedPane == .table)
            } bottom: {
                detailPane
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focusedPane, equals: .detail)
                    .paneFocusRing(focusedPane == .detail)
            }
        } right: {
            // Inspector-Spalte: KEIN äußerer ScrollView. Die drei Regionen
            // füllen zusammen exakt die Spaltenhöhe (ResizableVSplit3); lange
            // Inhalte (viele Partitionen, GPU-Hours-Rangliste) scrollen
            // INNERHALB ihrer Region — die Trenner sind ziehbar/persistiert.
            ResizableVSplit3 {
                gpuAllocationCardView
            } b: {
                diskQuotasCardView
            } c: {
                gpuHoursCardView
            }
            .slurmyContentBackground()
            .focusable()
            .focusEffectDisabled()
            .focused($focusedPane, equals: .inspector)
            .paneFocusRing(focusedPane == .inspector)
        }
    }

    private static let leftMinTop: CGFloat = 140
    /// Mindesthöhe des Detail-Panes. Seit das Detail auf macOS nicht mehr
    /// außen scrollt (siehe JobDetailView.macDetailLayout), braucht es Platz
    /// für den fixen Header, die Log-Kartenköpfe und die Aktionszeile —
    /// bei den früheren 170 pt wären die unteren Elemente unerreichbar
    /// abgeschnitten (vorher rettete der Außen-Scroll sie).
    private static let leftMinBottom: CGFloat = 260

    /// Estimated height of the jobs table at `rows` rows (filter bar + header +
    /// rows). Used to cap the table to its content so a short list leaves no
    /// whitespace under it. Die Maße kommen aus @ScaledMetric, damit die
    /// Schätzung bei größerer Textstufe (⌘+) mitwächst.
    private func tableContentHeight(rows: Int) -> CGFloat {
        filterBarH + tableHeaderH + CGFloat(max(1, rows)) * tableRowH + 12
    }

    #endif

    /// Konfigurierbares Grid: jedes Panel ist ein Widget, im Edit-Modus frei
    /// verschieb- und skalierbar. Inhalt kommt aus `dashboardWidgetView`.
    private var dashboardLayout: some View {
        DashboardGridView(store: dashboard, editing: editingDashboard) { widget in
            dashboardWidgetView(widget)
        }
    }

    @ViewBuilder
    private func dashboardWidgetView(_ widget: DashboardWidget) -> some View {
        switch widget {
        case .jobs:
            jobsWidget
        case .detail:
            detailPane
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .gpuAllocation:
            clusterCard {
                GpuAllocationStrip(
                    usage: vm.gpuUsage,
                    isLoading: !vm.initialFetchDone,
                    focusedPartition: nil
                ) { name in
                    sheetPartition = PartitionSelection(name: name)
                    Task { await vm.loadPartition(name) }
                }
            }
        case .diskQuotas:
            clusterCard {
                DiskQuotasCard(quotas: vm.diskQuotas, isLoading: vm.quotasLoading)
            }
        case .gpuHours:
            clusterCard {
                GpuHoursCard(
                    entries: vm.gpuHours,
                    currentUser: appState.credentials?.username,
                    isLoading: vm.hoursLoading,
                    isFocused: false,
                    onOpenFullView: { showGpuHoursSheet = true },
                    onRefresh: { Task { await vm.reloadGpuHours(force: true) } }
                )
            }
        }
    }

    /// Jobs-Widget: Filterleiste + Tabelle (die `table`-View bringt ihren
    /// eigenen `.focused(.table)` mit, daher hier kein zweiter Fokus).
    private var jobsWidget: some View {
        VStack(spacing: 0) {
            filterBar
            if let err = vm.error {
                ErrorBanner(message: err)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            table
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func clusterCard<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ScrollView { content().padding(12) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    #if os(macOS)
    /// Compact "own ↔ all users" switch with a person icon on each side; the
    /// active side glows in the accent. Flipping it animates the list update.
    private var allUsersToggle: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.fill")
                .foregroundColor(vm.allUsers ? Theme.textSecondary : Theme.accent)
            Toggle("", isOn: $vm.allUsers.animation(Motion.reduceMotionEnabled ? nil : .smooth(duration: 0.3)))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            Image(systemName: "person.3.fill")
                .foregroundColor(vm.allUsers ? Theme.accent : Theme.textSecondary)
        }
        .font(.caption)
        .help("Eigene Jobs ↔ alle Nutzer (u)")
    }
    #endif

    @ToolbarContentBuilder
    private var jobsToolbar: some ToolbarContent {
        #if os(iOS)
        if selectionMode {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fertig") { selectionMode = false; marked = [] }
            }
            ToolbarItem(placement: .principal) {
                Text(marked.isEmpty ? "Auswählen" : "\(marked.count) ausgewählt")
                    .font(.headline).foregroundColor(Theme.textPrimary)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                batchActionsMenu.disabled(marked.isEmpty)
                Spacer()
            }
        } else {
            ToolbarItem(placement: .topBarLeading) { connectionDot }
            ToolbarItem(placement: .topBarLeading) {
                Button("Auswählen") { selectionMode = true }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Inspector öffnet per Tap auf die Cluster-Leiste — daher hier
                // nicht nochmal als Button, um die Bar schlank zu halten.
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Aktualisieren")
                sortMenu
                filterMenu
                // iPad (reguläre Breite): Grid-Dashboard ein/aus direkt in der
                // Toolbar (zusätzlich zu Settings → „Dashboard (Jobs)"), plus
                // Layout bearbeiten, solange das Grid aktiv ist. iPhone
                // (compact) behält die feste Liste, daher dort ausgeblendet.
                if horizontalSizeClass == .regular {
                    Button { withMotion { dashboardEnabled.toggle() } } label: {
                        Image(systemName: dashboardEnabled ? "rectangle.3.group.fill" : "rectangle.3.group")
                    }
                    .accessibilityLabel(dashboardEnabled ? "Grid-Dashboard ausschalten" : "Grid-Dashboard einschalten")
                    if iPadDashboardActive {
                        Button { editingDashboard.toggle() } label: {
                            Image(systemName: editingDashboard ? "checkmark.circle.fill" : "slider.horizontal.3")
                        }
                        .accessibilityLabel(editingDashboard ? "Layout fertig bearbeiten" : "Layout bearbeiten")
                    }
                }
                Button { showNodesSheet.toggle() } label: { Image(systemName: "server.rack") }
                    .accessibilityLabel("Knoten-Übersicht")
                Button { showSubmit.toggle() } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel("Job einreichen")
            }
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            allUsersToggle
            Button { Task { await vm.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.pulse, options: .repeating, isActive: vm.loading)
            }
                .keyboardShortcut(Shortcut.refresh.key, modifiers: Shortcut.refresh.modifiers)
                .help("Aktualisieren (r)")
            // Interaktive Session = srun --pty in Terminal.app → nur macOS.
            Button { showInteractive.toggle() } label: { Image(systemName: "terminal") }
                .keyboardShortcut(Shortcut.interactiveSession.key, modifiers: Shortcut.interactiveSession.modifiers)
                .help("Interaktive Session (i — toggle)")
            Button { showSubmit.toggle() } label: { Image(systemName: "plus.circle.fill") }
                .keyboardShortcut(Shortcut.submitJob.key, modifiers: Shortcut.submitJob.modifiers)
                .help("sbatch (n — toggle)")
            Button { showNodesSheet.toggle() } label: { Image(systemName: "server.rack") }
                .keyboardShortcut(Shortcut.nodesOverview.key, modifiers: Shortcut.nodesOverview.modifiers)
                .help("Knoten-Übersicht (G — toggle)")
            Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                .keyboardShortcut(Shortcut.help.key, modifiers: Shortcut.help.modifiers)
                .help("Tastatur-Shortcuts (h — toggle)")
        }
        if dashboardEnabled {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingDashboard.toggle()
                } label: {
                    Image(systemName: editingDashboard ? "checkmark.circle.fill" : "slider.horizontal.3")
                        .foregroundColor(editingDashboard ? Theme.accent : Theme.textPrimary)
                }
                .help(editingDashboard ? "Layout fertig bearbeiten" : "Layout bearbeiten (verschieben/skalieren)")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withMotion { inspectorOpen.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(inspectorOpen ? Theme.accent : Theme.textPrimary)
                        .symbolVariant(inspectorOpen ? .fill : .none)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help(inspectorOpen ? "Inspector schliessen (⌘⌥0)" : "Inspector öffnen (⌘⌥0)")
            }
        }
        // Umschalter Split-/Grid-Ansicht lebt jetzt in den Einstellungen
        // (Settings → „Dashboard (Jobs)"), nicht mehr in der Toolbar.
        #endif
    }

    #if os(iOS)
    /// Treibt die iOS-Detail-Navigation: ein Tap im Normal-Modus setzt `cursor`
    /// und pusht das Detail. Im Auswahl-Modus wird NICHT navigiert (Markieren
    /// bleibt auf der Liste, Batch-Aktionen laufen über die untere Leiste).
    private var iosDetailPresented: Binding<Bool> {
        Binding(
            // Im Grid-Dashboard zeigt das Detail-Widget den Job inline — dann
            // NICHT zusätzlich pushen. `presentedJob` hält das Detail auch dann
            // offen, wenn der Job aus der Queue gealtert ist (cursor == nil) —
            // erst das Zurück-Navigieren des Nutzers räumt beides auf.
            get: { !iPadDashboardActive && !selectionMode && (cursor != nil || presentedJob != nil) },
            set: { if !$0 { cursor = nil; presentedJob = nil } }
        )
    }

    /// iPad mit großer Breite + aktiviertem Dashboard → Grid statt Liste/Push.
    /// iPhone (compact) bleibt immer bei der festen Liste.
    private var iPadDashboardActive: Bool {
        horizontalSizeClass == .regular && dashboardEnabled
    }

    /// Body-level partition-sheet presenter, active ONLY in iPad dashboard mode
    /// (where the inspector sheet that normally hosts it isn't mounted). Inert
    /// otherwise so it never double-presents with the inspector-nested one.
    private var dashboardPartitionBinding: Binding<PartitionSelection?> {
        Binding(get: { iPadDashboardActive ? sheetPartition : nil },
                set: { if iPadDashboardActive { sheetPartition = $0 } })
    }
    private var dashboardGpuHoursBinding: Binding<Bool> {
        Binding(get: { iPadDashboardActive ? showGpuHoursSheet : false },
                set: { if iPadDashboardActive { showGpuHoursSheet = $0 } })
    }
    #endif

    /// Cluster of invisible buttons that own the single-letter shortcuts.
    /// `r`, `i`, `n`, `h` (and `⌘⌥0`) live on toolbar buttons; the rest sit
    /// here. macOS swallows letter shortcuts while a TextField holds focus,
    /// so typing in the search field is not affected.
    /// Any modal is on top of the table — silence Job-section shortcuts so
    /// they don't fire while the user is reading help / submitting / etc.
    private var anyModalOpen: Bool {
        var open = showHelp || showSubmit || showInteractive || showGpuHoursSheet
            || sheetPartition != nil || logModal != nil || showNodesSheet
        #if os(iOS)
        // The cluster inspector is a sheet on iOS — its presence must also
        // silence the (hardware-keyboard) table shortcuts underneath.
        open = open || showInspectorSheet
        #endif
        return open
    }

    private var hiddenShortcuts: some View {
        ZStack {
            // ---- Always-active (intentionally outside the disabled group) ----
            Shortcut.hiddenButton(.clearSelection)       { handleEscape() }
            Shortcut.hiddenButton(.helpAlt)              { showHelp.toggle() }
            // `g` keeps cycling/closing the Partition sheet even when it's
            // already open — its whole purpose is to walk through partitions.
            Shortcut.hiddenButton(.cyclePartition)       { cyclePartitionSheet() }

            // Single Space binding for the whole Jobs section. Routes to
            // mark/unmark, inspector-modal-toggle, or modal-close depending
            // on context (see `dispatchSpaceAction()`).
            Button { dispatchSpaceAction() } label: { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

            // Inspector-only arrow nav. Disabled outside the Inspector so
            // the native Table arrow-row-navigation keeps working, and
            // disabled while any modal is open so sheets get the keys.
            Button { moveInspectorCursor(by: -1) } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                .disabled(focusedPane != .inspector || anyModalOpen)
            Button { moveInspectorCursor(by: +1) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                .disabled(focusedPane != .inspector || anyModalOpen)

            // ---- Job-context-only (disabled while a modal is open) ----
            modalScopedShortcuts
        }
    }

    @ViewBuilder
    private var modalScopedShortcuts: some View {
        Group {
            // Quit läuft über das System-Menü (⌘Q) — das frühere bare `q`
            // beendete die App (samt SSH-Session) bei einem einzigen
            // versehentlichen Tastendruck ohne Rückfrage.
            // ⌘F — Suche fokussieren (Eintrag im Help-Overlay kommt aus dem
            // Shortcut-Enum; dieses Binding hält beide synchron).
            Shortcut.hiddenButton(.focusSearch)          { focusSearchField() }
            Shortcut.hiddenButton(.toggleAllUsers)       { withMotion(.smooth(duration: 0.3)) { vm.allUsers.toggle() } }
            Shortcut.hiddenButton(.toggleAllUsersCmd)    { withMotion(.smooth(duration: 0.3)) { vm.allUsers.toggle() } }
            Shortcut.hiddenButton(.toggleRunningOnly)    { vm.runningOnly.toggle() }
            Shortcut.hiddenButton(.attachSelected)       { attachSelectedJob() }
            Shortcut.hiddenButton(.cancelSelected)       { requestCancelOfSelection() }
            Shortcut.hiddenButton(.batchQos)             { startBatch(.qos) }
            Shortcut.hiddenButton(.batchPartition)       { startBatch(.partition) }
            Shortcut.hiddenButton(.bookmarkSelected)     { bookmarkSelection() }
            Shortcut.hiddenButton(.editScript)           { editScriptOfSelection() }
            Shortcut.hiddenButton(.openTerminal)         { openShellInTerminal() }
            Shortcut.hiddenButton(.openBookmarks)        { switchToSection(.bookmarks) }
            Shortcut.hiddenButton(.prevSortColumn)       { cycleSort(by: -1) }
            Shortcut.hiddenButton(.prevSortColumnArrow)  { cycleSort(by: -1) }
            Shortcut.hiddenButton(.nextSortColumn)       { cycleSort(by: +1) }
            Shortcut.hiddenButton(.nextSortColumnArrow)  { cycleSort(by: +1) }
            Shortcut.hiddenButton(.toggleSortDir)        { toggleSortDirection() }
            Shortcut.hiddenButton(.toggleSortDirAltS)    { toggleSortDirection() }
            Shortcut.hiddenButton(.toggleSortDirAltD)    { toggleSortDirection() }
            // Vim-style cursor nav
            Shortcut.hiddenButton(.cursorDownVim)        { moveCursor(by: +1) }
            Shortcut.hiddenButton(.cursorUpVim)          { moveCursor(by: -1) }
            // Jump to first / last (Home/End + ⌘↑/⌘↓)
            Shortcut.hiddenButton(.cursorTop)            { jumpCursor(to: .first) }
            Shortcut.hiddenButton(.cursorBottom)         { jumpCursor(to: .last) }
            Shortcut.hiddenButton(.cursorTopCmd)         { jumpCursor(to: .first) }
            Shortcut.hiddenButton(.cursorBottomCmd)      { jumpCursor(to: .last) }
            // NB: no hidden ↑/↓ buttons here — that would swallow the keys
            // before the native Table can use them for row navigation. `j`/
            // `k` (above) and a focused Table are the two routes for cursor
            // movement. Space is routed via `dispatchSpaceAction()` in the
            // always-active cluster.
            // ⌘A — mark every visible row. Nur solange die Tabelle den Fokus
            // hält: Im Suchfeld (oder einem anderen Pane) muss ⌘A das normale
            // „Alles auswählen" des Texteditors bleiben — ein View-hierarchy-
            // Key-Equivalent würde es sonst VOR dem Field-Editor abfangen.
            Button { marked = Set(vm.filtered().map(\.id)) } label: { EmptyView() }
                .keyboardShortcut("a", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                .disabled(markAllSuppressed)
        }
        .disabled(anyModalOpen)
    }

    /// ⌘A nur in der Tabelle ausführen. macOS: das Pane-Fokus-Modell ist
    /// verlässlich (Suchfeld-Fokus ⇒ focusedPane == nil). iOS: kein
    /// Pane-Fokus auf Touch — dort genügt der Suchfeld-Wächter.
    private var markAllSuppressed: Bool {
        if searchFocused { return true }
        #if os(macOS)
        return focusedPane != .table
        #else
        return false
        #endif
    }

    /// ⌘F → Suchfeld fokussieren. Ab macOS 15 / iOS 17 über das
    /// `.searchFocused`-Binding; auf macOS 14 (kein `.searchFocused`) wird das
    /// NSSearchField der Toolbar direkt zum First Responder gemacht.
    private func focusSearchField() {
        if #available(macOS 15.0, iOS 17.0, *) {
            searchFocused = true
        } else {
            #if os(macOS)
            legacyFocusToolbarSearchField()
            #endif
        }
    }

    #if os(macOS)
    /// macOS-14-Fallback: das (AppKit-gebackene) Suchfeld in der Fenster-
    /// Titelleiste suchen und fokussieren. Best-effort — findet die Hierarchie
    /// kein NSSearchField, bleibt ⌘F folgenlos.
    private func legacyFocusToolbarSearchField() {
        guard let window = NSApp.keyWindow else { return }
        func findSearchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews {
                if let found = findSearchField(in: sub) { return found }
            }
            return nil
        }
        // Toolbar-Views hängen über dem contentView (Theme-Frame) — von dort
        // aus suchen, damit auch Titelbar-Accessories erfasst sind.
        let root = window.contentView?.superview ?? window.contentView
        if let root, let field = findSearchField(in: root) {
            window.makeFirstResponder(field)
        }
    }
    #endif

    private func toggleMarkAtCursor() {
        guard let id = cursor else { return }
        if marked.contains(id) {
            marked.remove(id)
        } else {
            marked.insert(id)
        }
        // Auto-advance in whichever direction the user was last navigating
        // — so range-marking with ⇧/Space walks the same way as the prior
        // ↑ / ↓ presses, not always downward.
        let rows = visibleJobs
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        let next = idx + lastDirection
        if next >= 0 && next < rows.count {
            cursor = rows[next].id
        }
    }

    // MARK: – Action helpers

    private func attachSelectedJob() {
        guard let job = selectedJob,
              job.isRunning,
              let me = appState.credentials?.username,
              job.user == me,
              let creds = appState.credentials else { return }
        TerminalLauncher.attach(jobId: job.jobId, credentials: creds)
    }

    private func requestCancelOfSelection() {
        let own = actionSet.filter {
            $0.user == appState.credentials?.username && ($0.isRunning || $0.isPending)
        }
        if !own.isEmpty { cancelConfirmJobs = own }
    }

    private func bookmarkSelection() {
        for j in actionSet {
            bookmarks.add(Bookmark(jobId: j.jobId, label: j.name))
        }
    }

    // MARK: – Batch-Aktionen (markierte Menge)

    /// Für die Aktion zulässige Jobs aus der aktuellen Auswahl (`actionSet`).
    private func eligible(_ action: BatchAction) -> [Job] {
        let me = appState.credentials?.username
        return actionSet.filter { action.isEligible($0, me: me) }
    }

    /// QoS/Partition-Optionen einmalig vom Cluster holen (für das Werte-Sheet).
    private func loadActionOptions() async {
        // Shared connection-wide cache — avoids refetching the cluster-static
        // lists here and again in every JobDetailView.
        if availableQos.isEmpty { availableQos = await appState.cachedAvailableQos() }
        if availablePartitions.isEmpty { availablePartitions = await appState.cachedAvailablePartitions() }
    }

    private func startBatch(_ action: BatchAction) {
        let jobs = eligible(action)
        guard !jobs.isEmpty else {
            batchResult = "Keine zulässigen Jobs für \(action.title)."
            return
        }
        if action.needsValue {
            Task { await loadActionOptions() }
            batchValueAction = action
        } else {
            batchConfirm = BatchConfirmation(action: action, jobs: jobs)
        }
    }

    /// Wendet die Aktion per-Job an (wie die TUI: einzelne Befehle, Per-Job-
    /// Fehler), fasst das Ergebnis zusammen und räumt die Auswahl auf.
    private func applyBatch(_ action: BatchAction, to jobs: [Job], value: String? = nil) {
        guard let slurm = appState.slurm else { return }
        Task {
            var ok = 0, failed = 0
            // Erste echte Fehlermeldung mitnehmen (SSHError.commandFailed trägt
            // das stderr von scontrol/scancel) — „2 Fehler" ohne Grund ist für
            // eine Cluster-mutierende Aktion wertlos.
            var firstError: String?
            if action == .cancel {
                // Batched scancel — one SSH round-trip for the whole selection
                // instead of one per job.
                do { try await slurm.cancelJobs(jobs.map(\.jobId)); ok = jobs.count }
                catch {
                    failed = jobs.count
                    firstError = error.localizedDescription
                }
            } else {
                for j in jobs {
                    // Stop mutating the cluster if the user disconnected mid-loop.
                    guard appState.slurm != nil else { break }
                    do {
                        switch action {
                        case .cancel:    break   // handled above (batched)
                        case .qos:       _ = try await slurm.updateJobQos(j.jobId, qos: value ?? "")
                        case .partition: _ = try await slurm.updateJobPartition(j.jobId, partition: value ?? "")
                        case .hold:      _ = try await slurm.holdJob(j.jobId)
                        case .release:   _ = try await slurm.releaseJob(j.jobId)
                        case .requeue:   _ = try await slurm.requeueJob(j.jobId)
                        }
                        ok += 1
                    } catch {
                        failed += 1
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
            }
            let valuePart = value.map { " → \($0)" } ?? ""
            let failPart = failed > 0
                ? ", \(failed) Fehler" + (firstError.map { " (\($0))" } ?? "")
                : ""
            batchResult = "\(action.title)\(valuePart): \(ok) ok" + failPart
            marked = []
            #if os(iOS)
            selectionMode = false
            #endif
            await vm.refresh()
        }
    }

    /// Ein Menü mit allen Batch-Aktionen (Eligible-Count, deaktiviert bei 0) —
    /// auf iOS in der Auswahl-Aktionsleiste, auf macOS in der Detailspalte.
    @ViewBuilder
    private var batchActionsMenu: some View {
        Menu {
            ForEach(BatchAction.allCases) { action in
                let n = eligible(action).count
                Button(role: action.isDestructive ? .destructive : nil) {
                    startBatch(action)
                } label: {
                    Label("\(action.title) (\(n))", systemImage: action.symbol)
                }
                .disabled(n == 0)
            }
            Divider()
            Button { bookmarkSelection() } label: {
                Label("Lesezeichen (\(actionSet.count))", systemImage: "bookmark")
            }
            .disabled(actionSet.isEmpty)
        } label: {
            Label("Aktionen", systemImage: "ellipsis.circle")
        }
    }

    private func editScriptOfSelection() {
        guard let job = selectedJob,
              job.user == appState.credentials?.username,
              let creds = appState.credentials else { return }
        Task {
            guard let script = try? await appState.slurm?.fetchBatchScript(job.jobId),
                  !script.isEmpty,
                  let details = try? await appState.slurm?.fetchJobDetails(job.jobId),
                  let path = details.value("Command")
            else { return }
            _ = script   // not needed locally — Terminal opens the remote path
            // Single-quote the remote path so a path with spaces/metacharacters
            // can't break the editor command (the whole remoteCommand is then
            // single-quoted again by TerminalLauncher for the ssh argument).
            let safePath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            await MainActor.run {
                TerminalLauncher.openSSH(
                    host: creds.host,
                    user: creds.username,
                    port: creds.port,
                    remoteCommand: "${EDITOR:-vim} \(safePath)"
                )
            }
        }
    }

    private func openShellInTerminal() {
        guard let creds = appState.credentials else { return }
        TerminalLauncher.openSSH(host: creds.host, user: creds.username, port: creds.port)
    }

    private func cyclePartitionSheet() {
        guard !vm.gpuUsage.isEmpty else { return }
        let parts = vm.gpuUsage.map(\.partition)
        // Derive the position from the ACTUALLY open sheet, so `g` stays in sync
        // even when the sheet was opened via the inspector (not via `g`) or the
        // partition list reordered. After the last, close it (a long `g`-mash
        // exits cleanly).
        let nextIdx: Int
        if let open = sheetPartition?.name, let i = parts.firstIndex(of: open) {
            nextIdx = i + 1
            if nextIdx >= parts.count { sheetPartition = nil; return }
        } else {
            nextIdx = 0
        }
        let name = parts[nextIdx]
        sheetPartition = PartitionSelection(name: name)
        Task { await vm.loadPartition(name) }
    }

    private func switchToSection(_ section: MainSection) {
        NotificationCenter.default.post(name: .switchSection, object: section)
    }

    // MARK: – Sort helpers

    /// Columns in the same order they appear in the Table. Used to cycle
    /// the primary sort key with y/← and c/→. Laufzeit/Speicher sortieren
    /// über numerische Schlüssel (siehe `Job`-Extension unten) — als Text
    /// landete „59:00" über „5:00:00" und „512M" über „8G".
    private static let sortColumns: [KeyPathComparator<Job>] = [
        .init(\.jobId,          order: .reverse),
        .init(\.name,           order: .forward),
        .init(\.state,          order: .forward),
        .init(\.user,           order: .forward),
        .init(\.qos,            order: .forward),
        .init(\.partition,      order: .forward),
        .init(\.gpus,           order: .reverse),
        .init(\.cpus,           order: .reverse),
        .init(\.memoryMB,       order: .forward),
        .init(\.runtimeSeconds, order: .reverse),
    ]

    private func cycleSort(by delta: Int) {
        let cols = Self.sortColumns
        let currentKey = sortOrder.first?.keyPath
        var idx = cols.firstIndex(where: { $0.keyPath == currentKey }) ?? 0
        idx = (idx + delta + cols.count) % cols.count
        var next = cols[idx]
        // Preserve current order direction across column changes.
        if let order = sortOrder.first?.order { next.order = order }
        sortOrder = [next]
    }

    private func toggleSortDirection() {
        guard var current = sortOrder.first else { return }
        current.order = current.order == .forward ? .reverse : .forward
        sortOrder = [current]
    }

    // MARK: – Tab / pane cycling

    /// `Tab` and `⇧Tab` walk through the panes inside the Jobs section:
    /// sidebar → table → detail → inspector → sidebar …
    private var paneCycleShortcuts: some View {
        ZStack {
            Button { cyclePane(by: +1) } label: { EmptyView() }
                .keyboardShortcut(.tab, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button { cyclePane(by: -1) } label: { EmptyView() }
                .keyboardShortcut(.tab, modifiers: .shift)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        // Don't fight modals — Tab inside a sheet stays a sheet-control.
        .disabled(anyModalOpen)
    }

    private func cyclePane(by delta: Int) {
        // Available panes, skipping inspector when it's collapsed (or when the
        // grid dashboard is active — there is no single inspector pane then).
        var order: [Pane] = [.sidebar, .table, .detail]
        #if os(macOS)
        if inspectorOpen && !dashboardEnabled { order.append(.inspector) }
        #else
        // iOS: the inspector is a SHEET, gated by showInspectorSheet — not the
        // macOS-only `inspectorOpen` AppStorage (which is irrelevant here).
        if showInspectorSheet { order.append(.inspector) }
        #endif

        let current = focusedPane ?? .table
        let idx = order.firstIndex(of: current) ?? 1
        let next = order[(idx + delta + order.count) % order.count]

        if next == .sidebar {
            // Sidebar lives in MainTabView — bridge via NotificationCenter.
            NotificationCenter.default.post(name: .focusSidebar, object: nil)
            focusedPane = nil
        } else {
            focusedPane = next
        }
    }

    // MARK: – Cursor navigation

    private enum JumpTarget { case first, last }

    /// Materialised, sorted, filtered job list — the row order the user
    /// sees right now in the table.
    /// Materialised, sorted, filtered job list — the row order the user sees.
    /// Memoized in the VM so the table, height calc and cursor math don't each
    /// re-sort within a single render.
    private var visibleJobs: [Job] {
        vm.visibleJobs(sortOrder: sortOrder, runningFirst: runningJobsFirst)
    }

    /// Keep only the marks that are currently visible (after the active
    /// filters), so the count and bulk actions match what the user sees.
    private func pruneMarkedToVisible() {
        guard !marked.isEmpty else { return }
        let visible = Set(vm.filteredJobs.map(\.id))
        let pruned = marked.intersection(visible)
        if pruned != marked { marked = pruned }
    }

    /// Make sure a cursor exists whenever we have data, so the first ↑/↓
    /// press actually moves something.
    private func ensureCursor() {
        let rows = visibleJobs
        guard !rows.isEmpty else { cursor = nil; return }
        if let c = cursor, rows.contains(where: { $0.id == c }) { return }
        #if os(macOS)
        // Tastatur-Cursor: erste Zeile vorauswählen (Detail-Pane zeigt sie).
        cursor = rows.first?.id
        #else
        // iOS: keine Auto-Auswahl — sonst würde die Detailansicht beim Laden
        // sofort gepusht. Auswahl entsteht erst durch Antippen einer Zeile.
        cursor = nil
        #endif
    }

    private func moveCursor(by delta: Int) {
        lastDirection = delta >= 0 ? +1 : -1
        let rows = visibleJobs
        guard !rows.isEmpty else { return }
        guard let c = cursor, let idx = rows.firstIndex(where: { $0.id == c }) else {
            cursor = rows.first?.id
            return
        }
        let next = max(0, min(rows.count - 1, idx + delta))
        cursor = rows[next].id
    }

    private func jumpCursor(to target: JumpTarget) {
        let rows = visibleJobs
        guard !rows.isEmpty else { return }
        cursor = (target == .first ? rows.first : rows.last)?.id
    }

    // MARK: – Space dispatcher / Inspector cursor

    /// One Space binding for the whole section. Two `keyboardShortcut(.space)`
    /// buttons in the same view fire unpredictably, so we centralise routing
    /// here.
    private func dispatchSpaceAction() {
        if anyModalOpen { closeTopmostModal(); return }
        switch focusedPane {
        case .inspector: triggerInspectorAction()
        case .table:     toggleMarkAtCursor()
        case .detail:    requestExpandActiveLog()
        default:         break
        }
    }

    /// Ask the live detail pane to raise its active log. The detail view owns
    /// the log text, so it computes which stream to show and hands the modal
    /// payload back via the `onExpandLog` callback wired into `logModal`.
    private func requestExpandActiveLog() {
        guard selectedJob != nil, marked.isEmpty else { return }
        NotificationCenter.default.post(name: .requestExpandActiveLog, object: nil)
    }

    /// Like `handleEscape()` but only closes the topmost modal — no
    /// selection/cursor/search reset.
    private func closeTopmostModal() {
        if logModal != nil        { logModal = nil; return }
        if showNodesSheet         { showNodesSheet = false; return }
        if sheetPartition  != nil { sheetPartition = nil; return }
        if showGpuHoursSheet      { showGpuHoursSheet = false; return }
        if showHelp               { showHelp = false; return }
        if showSubmit             { showSubmit = false; return }
        if showInteractive        { showInteractive = false; return }
    }

    @ViewBuilder
    private func partitionSheet(_ sel: PartitionSelection) -> some View {
        PartitionSheetView(
            partition: sel.name,
            usage: vm.gpuUsage.first(where: { $0.partition == sel.name }),
            nodes: vm.partitionNodes[sel.name] ?? [],
            details: vm.partitionDetails[sel.name] ?? [:],
            onClose: { sheetPartition = nil },
            onRefresh: { Task { await vm.loadPartition(sel.name, force: true) } }
        )
        .environmentObject(appState)
    }

    @ViewBuilder
    private var gpuHoursSheet: some View {
        GpuHoursSheetView()
            .environmentObject(appState)
    }

    private var nodesSheet: some View {
        NodesOverviewView()
            .environmentObject(appState)
    }

    /// Öffnet den Cluster-Inspector — auf iOS als Sheet, auf macOS als Pane.
    private func openInspector() {
        #if os(iOS)
        showInspectorSheet = true
        #else
        withMotion { inspectorOpen = true }
        #endif
    }

    private func firstInspectorItem() -> InspectorCursor {
        if let first = vm.gpuUsage.first?.partition { return .partition(first) }
        return .gpuHours
    }

    private func inspectorOrder() -> [InspectorCursor] {
        vm.gpuUsage.map { InspectorCursor.partition($0.partition) } + [.gpuHours]
    }

    private func moveInspectorCursor(by delta: Int) {
        let order = inspectorOrder()
        guard !order.isEmpty else { return }
        let current = inspectorCursor ?? firstInspectorItem()
        let idx = order.firstIndex(of: current) ?? 0
        let next = (idx + delta + order.count) % order.count
        inspectorCursor = order[next]
    }

    private func triggerInspectorAction() {
        guard let cur = inspectorCursor else { return }
        switch cur {
        case .partition(let name):
            if sheetPartition?.name == name {
                sheetPartition = nil
            } else {
                sheetPartition = PartitionSelection(name: name)
                Task { await vm.loadPartition(name) }
            }
        case .gpuHours:
            showGpuHoursSheet.toggle()
        }
    }

    // MARK: – Esc stack

    private func handleEscape() {
        if logModal != nil { logModal = nil; return }
        if showNodesSheet { showNodesSheet = false; return }
        if sheetPartition != nil { sheetPartition = nil; return }
        if showGpuHoursSheet { showGpuHoursSheet = false; return }
        if showHelp { showHelp = false; return }
        if showSubmit { showSubmit = false; return }
        if showInteractive { showInteractive = false; return }
        if !marked.isEmpty { marked = []; return }
        #if os(iOS)
        if cursor != nil || presentedJob != nil { cursor = nil; presentedJob = nil; return }
        #else
        if cursor != nil { cursor = nil; return }
        #endif
        if !vm.search.isEmpty { vm.search = ""; return }
    }

    private var leadingPane: some View {
        ZStack {
            #if os(iOS)
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                // iPhone: Cluster-Leiste immer sichtbar (Tap öffnet das Sheet).
                compactClusterBar
                Divider().background(Theme.border.opacity(0.6))
                leadingStack
            }
            #else
            // Kein opaker Pane-Boden mehr: Der Glas-Untergrund kommt von
            // paneLayout (.slurmyContentBackground) — die Tabelle schwebt
            // als eingerückte Frost-Karte darüber, sodass der
            // "Hinter-Hintergrund" bei aktivem Liquid Glass sichtbar ist.
            leadingStack
                .slurmyFrostSurface()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
                .padding(10)
            #endif
        }
    }

    /// Filterleiste + Fehlerbanner + Tabelle/Liste — gemeinsamer Kern beider
    /// Plattform-Varianten von `leadingPane`.
    private var leadingStack: some View {
        VStack(spacing: 0) {
            // macOS: collapsed inspector = just collapsed; no compact cluster
            // strip — the info simply isn't shown until the column is opened.
            filterBar
            if let err = vm.error {
                ErrorBanner(message: err)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            jobsListing
        }
    }

    /// macOS/iPad-Vollbild: `Table`. iPhone (kompakte Breite): native Zeilenliste,
    /// da `Table` dort nur die erste Spalte zeigt.
    @ViewBuilder
    private var jobsListing: some View {
        #if os(iOS)
        // Im Auswahl-Modus immer die kompakte Liste zeigen — nur sie hat die
        // Touch-Affordanzen zum Markieren (Tap/Swipe). Die Table bewegt per
        // Tap nur den Einzel-Cursor, Batch-Aktionen wären dort eine Sackgasse.
        if horizontalSizeClass == .compact || selectionMode { jobListCompact } else { table }
        #else
        table
        #endif
    }

    #if os(iOS)
    // MARK: – iOS kompakte Jobs-Liste (Touch)

    private static let sortColumnLabels =
        ["ID", "Name", "Status", "User", "QoS", "Partition", "GPU", "CPU", "Speicher", "Laufzeit"]

    private var jobListCompact: some View {
        let real = visibleJobs
        let initialLoad = !vm.initialFetchDone && real.isEmpty
        let data = initialLoad ? Self.skeletonJobs : real
        return List {
            ForEach(data) { job in
                Button {
                    if selectionMode { toggleMark(job) } else { cursor = job.id }
                } label: { jobRowCompact(job) }
                    .buttonStyle(.plain)
                    .listRowBackground(cursor == job.id ? Theme.surfaceElevated : Theme.surface)
                    .listRowSeparatorTint(Theme.border.opacity(0.5))
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            // Swipe-Markieren führt direkt in den Auswahl-Modus,
                            // damit die Aktionsleiste erscheint.
                            toggleMark(job)
                            selectionMode = true
                        } label: {
                            Label(marked.contains(job.id) ? "Entmarken" : "Markieren",
                                  systemImage: marked.contains(job.id) ? "checkmark.square" : "square")
                        }
                        .tint(Theme.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if isOwn(job) && (job.isRunning || job.isPending) {
                            Button(role: .destructive) { cancelConfirmJobs = [job] } label: {
                                Label("scancel", systemImage: "xmark.circle")
                            }
                        }
                        Button { bookmarks.add(Bookmark(jobId: job.jobId, label: job.name)) } label: {
                            Label("Lesezeichen", systemImage: "bookmark")
                        }
                        .tint(Theme.purple)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .slurmyContentBackground()
        .refreshable { await vm.refresh() }   // Pull-to-refresh (touch)
        .redacted(reason: initialLoad ? .placeholder : [])
        .overlay {
            if !initialLoad && data.isEmpty {
                ContentUnavailableView("Keine Jobs", systemImage: "tray",
                                       description: Text("Passe Filter oder Suche an."))
            }
        }
    }

    private func jobRowCompact(_ job: Job) -> some View {
        let c = Theme.stateColor(job.state)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if selectionMode {
                    Image(systemName: marked.contains(job.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(marked.contains(job.id) ? Theme.accent : Theme.textSecondary.opacity(0.5))
                } else if marked.contains(job.id) {
                    Image(systemName: "checkmark.square.fill").font(.caption).foregroundColor(Theme.accent)
                }
                Circle().fill(c).frame(width: 8, height: 8)
                Text("#\(job.jobId)").font(.callout.monospaced()).foregroundColor(Theme.textPrimary)
                Text(job.name).font(.callout).foregroundColor(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(job.state).font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(c.opacity(0.18)).foregroundColor(c).clipShape(Capsule())
            }
            HStack(spacing: 5) {
                Text(job.user).foregroundColor(Theme.textSecondary)
                rowSep; Text(job.partition).foregroundColor(Theme.cyan)
                if job.gpus > 0 { rowSep; Text("\(job.gpus) GPU").foregroundColor(Theme.purple) }
                rowSep; Text("\(job.cpus)c·\(job.memory)").foregroundColor(Theme.textSecondary)
                rowSep; Text(job.runtime).foregroundColor(Theme.textSecondary).monospaced()
                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var rowSep: some View { Text("·").foregroundColor(Theme.textSecondary.opacity(0.5)) }

    private func toggleMark(_ job: Job) {
        if marked.contains(job.id) { marked.remove(job.id) } else { marked.insert(job.id) }
    }

    private func isOwn(_ job: Job) -> Bool { job.user == appState.credentials?.username }

    // MARK: – iOS Toolbar-Menüs

    private var sortMenu: some View {
        Menu {
            Picker("Sortieren", selection: sortKeySelection) {
                ForEach(Array(Self.sortColumnLabels.enumerated()), id: \.offset) { i, label in
                    Text(label).tag(i)
                }
            }
            Divider()
            Button { toggleSortDirection() } label: {
                Label(sortAscending ? "Aufsteigend" : "Absteigend",
                      systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Alle Nutzer", isOn: $vm.allUsers)
            Toggle("Nur laufende", isOn: $vm.runningOnly)
        } label: {
            Image(systemName: (vm.allUsers || vm.runningOnly)
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    private var connectionDot: some View {
        // Breathes while connecting/degraded, calm when connected.
        BreathingDot(color: jobsStatusColor, active: connectionUnsettled, size: 10)
            .accessibilityLabel(Text(appState.connectionStatus.label))
    }

    private var connectionUnsettled: Bool {
        switch appState.connectionStatus {
        case .connecting, .degraded: return true
        default: return false
        }
    }

    private var jobsStatusColor: Color {
        switch appState.connectionStatus {
        case .connected:    return Theme.success
        case .connecting:   return Theme.warning
        case .degraded:     return Theme.warning
        case .failed:       return Theme.danger
        case .disconnected: return Theme.textSecondary
        }
    }

    private var sortKeySelection: Binding<Int> {
        Binding(
            get: { Self.sortColumns.firstIndex(where: { $0.keyPath == sortOrder.first?.keyPath }) ?? 0 },
            set: { idx in
                var next = Self.sortColumns[idx]
                if let order = sortOrder.first?.order { next.order = order }
                sortOrder = [next]
            }
        )
    }

    private var sortAscending: Bool { (sortOrder.first?.order ?? .forward) == .forward }
    #endif

    /// 1-line cluster status bar shown when the Inspector is closed. Clicking
    /// any chip re-opens the Inspector for the full card view.
    private var compactClusterBar: some View {
        let initialLoad = !vm.initialFetchDone
        return VStack(spacing: 0) {
            GpuAllocationMiniStrip(usage: vm.gpuUsage, isLoading: initialLoad) {
                openInspector()
            }
            if vm.quotasLoading || !vm.diskQuotas.isEmpty {
                Divider().background(Theme.border.opacity(0.4))
                DiskQuotasMiniStrip(quotas: vm.diskQuotas, isLoading: vm.quotasLoading) {
                    openInspector()
                }
            }
        }
    }

    /// Right-hand cluster Inspector: GPU Allocation (vertical, full), Disk
    /// Quotas (full), GPU Hours (full). Empty data + initial-load state is
    /// rendered as a redacted skeleton with shimmer.
    private var inspectorPane: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    gpuAllocationCardView
                    diskQuotasCardView
                    gpuHoursCardView
                }
                .padding(12)
            }
        }
    }

    // Shared cluster cards — reused by the resizable macOS cluster column and the
    // scrolling inspector pane (iOS sheet / inspector toggle).

    private var gpuAllocationCardView: some View {
        let focusedPartition: String? = {
            guard focusedPane == .inspector,
                  case .partition(let n) = inspectorCursor else { return nil }
            return n
        }()
        return GpuAllocationStrip(
            usage: vm.gpuUsage,
            isLoading: !vm.initialFetchDone,
            focusedPartition: focusedPartition
        ) { name in
            sheetPartition = PartitionSelection(name: name)
            Task { await vm.loadPartition(name) }
        }
    }

    private var diskQuotasCardView: some View {
        DiskQuotasCard(quotas: vm.diskQuotas, isLoading: vm.quotasLoading)
    }

    private var gpuHoursCardView: some View {
        let gpuHoursFocused = focusedPane == .inspector && inspectorCursor == .gpuHours
        return GpuHoursCard(
            entries: vm.gpuHours,
            currentUser: appState.credentials?.username,
            isLoading: vm.hoursLoading,
            isFocused: gpuHoursFocused,
            onOpenFullView: { showGpuHoursSheet = true },
            onRefresh: { Task { await vm.reloadGpuHours(force: true) } }
        )
    }


    @ViewBuilder
    private var detailPane: some View {
        if !marked.isEmpty {
            let jobs = vm.allJobs.filter { marked.contains($0.id) }
            MultiSelectionPlaceholder(
                count: marked.count,
                ownCount: jobs.filter { $0.user == appState.credentials?.username }.count
            ) {
                batchActionsMenu
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent.opacity(0.18))
                    .foregroundColor(Theme.accent)
                    .clipShape(Capsule())
            }
        } else if let job = detailJob {
            JobDetailView(job: job, onExpandLog: { logModal = $0 })
                .id(job.id)
                .environmentObject(appState)
        } else {
            EmptyDetailPlaceholder()
        }
    }

    /// The job under the cursor (single-select), used by the detail pane.
    private var selectedJob: Job? {
        guard let id = cursor else { return nil }
        return vm.allJobs.first(where: { $0.id == id })
    }

    /// Job für die Detail-Ansicht. iOS (gepushte Navigation): fällt auf den
    /// `presentedJob`-Snapshot zurück, wenn der Job die Queue verlassen hat —
    /// die letzten Logs bleiben so lesbar, statt unter dem Nutzer wegzupoppen.
    /// macOS / iPad-Dashboard behalten das bisherige Verhalten (Platzhalter).
    private var detailJob: Job? {
        #if os(iOS)
        if let live = selectedJob { return live }
        return iPadDashboardActive ? nil : presentedJob
        #else
        return selectedJob
        #endif
    }

    /// Effective bulk-action target. If anything is space-marked, use that.
    /// Otherwise fall back to the single cursor row.
    private var actionSet: [Job] {
        if !marked.isEmpty {
            return vm.allJobs.filter { marked.contains($0.id) }
        } else if let job = selectedJob {
            return [job]
        }
        return []
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(Theme.success).frame(width: 8, height: 8)
                Text("\(running)").foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text("laufend").foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 6) {
                Circle().fill(Theme.warning).frame(width: 8, height: 8)
                Text("\(pending)").foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text("wartend").foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundColor(Theme.purple)
                Text("\(gpus) GPU").foregroundColor(Theme.textPrimary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if !marked.isEmpty {
                Text("\(marked.count) markiert")
                    .foregroundColor(Theme.accent)
                    .contentTransition(.numericText())
                    .transition(.opacity)
            }
            if vm.runningOnly {
                Text("nur laufende")
                    .foregroundColor(Theme.warning)
                    .transition(.opacity)
            }
            Text("\(filteredCount) sichtbar")
                .foregroundColor(Theme.textSecondary)
                .contentTransition(.numericText())
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface)
        // Count-ups roll smoothly as the cluster changes (honours Reduce Motion).
        .motion(Motion.smooth, value: vm.stats)
        .motion(Motion.smooth, value: filteredCount)
        .motion(Motion.snappy, value: marked.isEmpty)
    }

    private var table: some View {
        let real = visibleJobs
        let initialLoad = !vm.initialFetchDone && real.isEmpty
        let data = initialLoad ? Self.skeletonJobs : real
        // Column widths are derived from the actual job set (not the
        // skeleton) so they reflect real Slurm output. During the initial
        // load we fall back to the skeleton widths so the table doesn't
        // visibly resize on first data arrival. Memoisiert im VM — die
        // Berechnung lief sonst bei jedem Body-Durchlauf über alle Zeilen.
        let sizing = vm.columnSizing(skeleton: Self.skeletonJobs, propPx: propPx, monoPx: monoPx)
        return ScrollViewReader { proxy in
        Table(data, selection: $cursor, sortOrder: $sortOrder) {
            TableColumn("ID", value: \.jobId) { job in
                HStack(spacing: 6) {
                    Image(systemName: marked.contains(job.id) ? "checkmark.square.fill" : "square")
                        .font(.caption)
                        .foregroundColor(marked.contains(job.id) ? Theme.accent : Theme.textSecondary.opacity(0.45))
                    Circle().fill(Theme.stateColor(job.state)).frame(width: 8, height: 8)
                    Text(job.jobId).font(.callout.monospaced())
                        .cellForeground(Theme.textPrimary)
                }
            }
            .width(sizing.id + 22)

            TableColumn("Name", value: \.name) { job in
                Text(job.name)
                    .cellForeground(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // min < ideal: Lange ML-Run-Namen dürfen die Spalte nicht starr
            // aufblasen und Laufzeit/Node aus dem Pane schieben — der Name
            // trunkiert ohnehin mittig.
            .width(min: 100, ideal: sizing.name)

            TableColumn("Status", value: \.state) { job in
                Text(job.state)
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.stateColor(job.state).opacity(0.18))
                    .foregroundColor(Theme.stateColor(job.state))
                    .clipShape(Capsule())
            }
            .width(sizing.state)

            TableColumn("User", value: \.user) { job in
                Text(job.user).cellForeground(Theme.textSecondary).lineLimit(1)
            }
            .width(sizing.user)

            TableColumn("QoS", value: \.qos) { job in
                let qc = Theme.qosColor(job.qos)
                Text(job.qos)
                    .foregroundColor(qc)
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(qc.opacity(0.15))
                    .clipShape(Capsule())
            }
            .width(sizing.qos)

            TableColumn("Part", value: \.partition) { job in
                Text(job.partition).cellForeground(Theme.cyan).font(.callout.bold())
            }
            .width(sizing.partition)

            TableColumn("GPU", value: \.gpus) { job in
                Text(job.gpus > 0 ? "\(job.gpus)" : "—")
                    .cellForeground(job.gpus > 0 ? Theme.purple : Theme.textSecondary)
                    .font(.callout.monospacedDigit())
            }
            .width(sizing.gpu)

            TableColumn("CPU/Mem", value: \.cpus) { job in
                HStack(spacing: 4) {
                    Text("\(job.cpus)")
                        .cellForeground(Theme.textPrimary)
                        .font(.callout.monospacedDigit())
                    Text("·")
                        .cellForeground(Theme.textSecondary)
                    Text(job.memory)
                        .cellForeground(Theme.textSecondary)
                        .font(.caption.monospacedDigit())
                }
            }
            .width(sizing.cpuMem)

            // Numerischer Sortier-Schlüssel: als Text landete „59:00" über
            // „5:00:00" und Tages-Präfixe („1-03:44:12") sortierten falsch.
            TableColumn("Laufzeit", value: \.runtimeSeconds) { job in
                Text(job.runtime).cellForeground(Theme.textSecondary).font(.callout.monospaced())
            }
            .width(sizing.runtime)

            TableColumn("Node / Grund") { job in
                if !job.reason.isEmpty {
                    Text(job.reason)
                        .cellForeground(Theme.warning)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(job.node)
                        .cellForeground(Theme.textSecondary)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                }
            }
            .width(min: 80, ideal: sizing.nodeReason)
        }
        // Right-click a row to copy fields — a SwiftUI Table isn't text-
        // selectable, so this is how you get a job's ID / name / node onto the
        // clipboard.
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            if let id = ids.first, let job = real.first(where: { $0.id == id }) {
                #if os(iOS)
                // Touch-Pfad fürs iPad: Markieren/scancel/Lesezeichen per
                // Long-Press — die Swipe-Gesten der kompakten Liste existieren
                // in der Table nicht. „Markieren" wechselt in den Auswahl-
                // Modus, dort übernimmt die kompakte Liste (Tap/Swipe).
                Button {
                    toggleMark(job)
                    selectionMode = true
                } label: {
                    Label(marked.contains(job.id) ? "Entmarken" : "Markieren",
                          systemImage: marked.contains(job.id) ? "checkmark.square" : "square")
                }
                if isOwn(job) && (job.isRunning || job.isPending) {
                    Button(role: .destructive) { cancelConfirmJobs = [job] } label: {
                        Label("scancel", systemImage: "xmark.circle")
                    }
                }
                Button { bookmarks.add(Bookmark(jobId: job.jobId, label: job.name)) } label: {
                    Label("Lesezeichen", systemImage: "bookmark")
                }
                Divider()
                #endif
                Button("Job-ID kopieren") { Clipboard.copy(job.jobId) }
                Button("Name kopieren") { Clipboard.copy(job.name) }
                if !job.node.isEmpty, job.node != "—" {
                    Button("Node kopieren") { Clipboard.copy(job.node) }
                }
                Button("User kopieren") { Clipboard.copy(job.user) }
                Divider()
                Button("Zeile kopieren (Tab-getrennt)") {
                    Clipboard.copy([
                        job.jobId, job.name, job.state, job.user, job.qos,
                        job.partition, "\(job.gpus)", job.runtime,
                        job.reason.isEmpty ? job.node : job.reason
                    ].joined(separator: "\t"))
                }
            }
        }
        .scrollContentBackground(.hidden)
        // Opaker Boden kommt von der Karte in `leadingPane`; die System-
        // Zeilenstreifen müssen aus — sie sampeln als Vibrancy den Desktop
        // und banden sonst durch den Content (sichtbar v. a. im Dark Mode).
        .plainRowBackgrounds()
        .focused($focusedPane, equals: .table)
        .focusable()
        .focusEffectDisabled()
        .redacted(reason: initialLoad ? .placeholder : [])
        .shimmering(initialLoad)
        .motion(.smooth(duration: 0.4), value: vm.initialFetchDone)
        .overlay {
            if !initialLoad && real.isEmpty {
                SlurmyEmptyState(
                    title: "Keine Jobs",
                    message: vm.search.isEmpty
                        ? "Alles ruhig im Cluster."
                        : "Nichts passt zu deiner Suche.",
                    mascotWidth: 200
                )
            }
        }
        .onAppear { scrollToCursor(proxy) }
        }
    }

    // MARK: – Stats

    private var running: Int { vm.stats.running }
    private var pending: Int { vm.stats.pending }
    private var gpus: Int { vm.stats.gpus }
    private var filteredCount: Int { vm.filteredJobs.count }

    /// Plausibly-shaped job rows used while the first squeue fetch is in
    /// flight. Combined with `.redacted(.placeholder)` they render as grey
    /// shimmering bars instead of an empty table. Each entry needs a unique
    /// `jobId` because `Job.id` is computed from it.
    private static let skeletonJobs: [Job] = (0..<10).map { i in
        Job(
            jobId: "skeleton-\(i)",
            name: String(repeating: "•", count: 14),
            user: String(repeating: "•", count: 8),
            state: i.isMultiple(of: 3) ? "PD" : "R",
            partition: "p2",
            qos: "basic",
            gpus: 1,
            cpus: 8,
            memory: "16G",
            runtime: "00:00:00",
            node: "—",
            reason: ""
        )
    }
}

/// Pre-computed pixel widths for each column based on the widest content
/// currently in the job list. Per-char widths are conservative and the
/// padding only covers SwiftUI Table's actual cell gutters — no extra
/// reserve for sort indicators (they overlap the cell on macOS).
/// Auf File-Ebene (nicht in JobsView), damit das ViewModel das Ergebnis
/// memoizen kann; die Zeichenbreiten kommen als @ScaledMetric-Werte herein
/// und skalieren so mit der Textgröße.
private struct ColumnSizing {
    let id, name, state, user, qos, partition, gpu, cpuMem, runtime, nodeReason: CGFloat

    init(jobs: [Job], propPx: CGFloat = 6.5, monoPx: CGFloat = 7.6) {
        let cellPad: CGFloat = 16   // 8 px on each side of a Table cell
        let pillPad: CGFloat = 14   // capsule chrome around a pill cell
        // Obergrenzen skalieren mit der Textgröße mit (Basis: propPx 6.5).
        let capScale = propPx / 6.5

        func widest(_ values: [String], px: CGFloat, padding: CGFloat, minimum: CGFloat) -> CGFloat {
            let chars = values.map(\.count).max() ?? 0
            return max(minimum, CGFloat(chars) * px + padding)
        }

        // ID column has a status dot (8 px) + 6 px spacing in front of the text
        self.id = widest(
            jobs.map(\.jobId), px: monoPx,
            padding: cellPad + 14,
            minimum: 70
        )
        // Gedeckelt: 36+-Zeichen-ML-Run-Namen drückten sonst die hinteren
        // Spalten (Laufzeit, Node/Reason) aus dem sichtbaren Bereich.
        self.name = min(
            widest(jobs.map(\.name), px: propPx, padding: cellPad, minimum: 100),
            240 * capScale
        )
        self.state = widest(
            jobs.map(\.state), px: propPx,
            padding: cellPad + pillPad,
            minimum: 50
        )
        self.user = widest(
            jobs.map(\.user), px: propPx,
            padding: cellPad,
            minimum: 60
        )
        self.qos = widest(
            jobs.map(\.qos), px: propPx,
            padding: cellPad + pillPad,
            minimum: 60
        )
        self.partition = widest(
            jobs.map(\.partition), px: propPx,
            padding: cellPad,
            minimum: 38
        )
        self.gpu = widest(
            jobs.map { $0.gpus > 0 ? "\($0.gpus)" : "—" }, px: monoPx,
            padding: cellPad,
            minimum: 38
        )
        self.cpuMem = widest(
            jobs.map { "\($0.cpus) · \($0.memory)" }, px: monoPx,
            padding: cellPad,
            minimum: 75
        )
        self.runtime = widest(
            jobs.map(\.runtime), px: monoPx,
            padding: cellPad,
            minimum: 70
        )
        let reasonWidth = widest(
            jobs.map(\.reason), px: propPx, padding: cellPad, minimum: 0
        )
        let nodeWidth = widest(
            jobs.map(\.node), px: monoPx, padding: cellPad, minimum: 0
        )
        self.nodeReason = min(max(80, max(reasonWidth, nodeWidth)), 220 * capScale)
    }
}

/// Zellen-Vordergrund für die Jobs-Table. Ersetzt das frühere cursor-basierte
/// Hardcoded-Weiß: SwiftUI setzt `backgroundProminence == .increased` NUR für
/// die wirklich betonte (akzentfarbene) Selektion — bei der grauen, unbetonten
/// Auswahl (Tabelle nicht First Responder, z. B. Fokus im Detail/Suchfeld)
/// bleibt die Grundfarbe lesbar, statt Weiß auf Hellgrau zu rendern.
private struct CellForeground: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence
    let base: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color.white : base)
    }
}

private extension View {
    func cellForeground(_ base: Color) -> some View {
        modifier(CellForeground(base: base))
    }

    /// `.searchFocused` existiert erst ab macOS 15 / iOS 17. Auf macOS 14 ist
    /// das Binding inert — dort fokussiert der ⌘F-Handler das Toolbar-
    /// NSSearchField direkt (siehe `legacyFocusToolbarSearchField`).
    @ViewBuilder
    func searchFocusedCompat(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, iOS 17.0, *) {
            self.searchFocused(binding)
        } else {
            self
        }
    }
}

// MARK: – Numerische Sortier-Schlüssel
// `runtime` ([DD-]HH:MM:SS) und `memory` (Zahl + Einheits-Suffix) sind
// Anzeige-Strings — als Text sortiert landet „59:00" über „5:00:00" und
// „512M" über „8G". Diese Schlüssel sortieren numerisch; angezeigt wird
// weiterhin der Original-String.
private extension Job {
    /// Laufzeit in Sekunden (squeue %M: „MM:SS", „HH:MM:SS", „D-HH:MM:SS").
    var runtimeSeconds: Int {
        var days = 0
        var clock = runtime[...]
        if let dash = clock.firstIndex(of: "-") {
            days = Int(clock[..<dash]) ?? 0
            clock = clock[clock.index(after: dash)...]
        }
        var seconds = 0
        for part in clock.split(separator: ":") {
            seconds = seconds * 60 + (Int(part) ?? 0)
        }
        return days * 86_400 + seconds
    }

    /// Speicher in MB (squeue %m: Zahl + K/M/G/T, optionaler n/c-Qualifier).
    var memoryMB: Double {
        var s = Substring(memory.trimmingCharacters(in: .whitespaces))
        if s.hasSuffix("n") || s.hasSuffix("c") { s = s.dropLast() }
        var multiplier = 1.0
        switch s.last {
        case "K", "k": multiplier = 1.0 / 1024;  s = s.dropLast()
        case "M", "m": multiplier = 1;           s = s.dropLast()
        case "G", "g": multiplier = 1024;        s = s.dropLast()
        case "T", "t": multiplier = 1024 * 1024; s = s.dropLast()
        default: break
        }
        return (Double(s) ?? 0) * multiplier
    }
}

private struct EmptyDetailPlaceholder: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            SlurmyEmptyState(
                title: "Job auswählen",
                message: "Wähle links einen Job – Slurmy zeigt dir Details, Logs und Live-GPU-Stats.",
                mascotWidth: 240
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PartitionSelection: Identifiable {
    let name: String
    var id: String { name }
}

private struct MultiSelectionPlaceholder<Actions: View>: View {
    let count: Int
    let ownCount: Int
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(Theme.textSecondary.opacity(0.5))
                Text("\(count) Jobs ausgewählt")
                    .font(.title3.bold())
                    .foregroundColor(Theme.textPrimary)
                if ownCount > 0 {
                    Text("\(ownCount) eigene")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }
                actions()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    /// Posted by the Jobs section when Tab cycles back into the sidebar.
    static let focusSidebar = Notification.Name("SlurmIOS.focusSidebar")
    /// Posted when Space is pressed with the detail pane focused — the live
    /// JobDetailView answers by raising its active log in a glass modal.
    static let requestExpandActiveLog = Notification.Name("SlurmIOS.requestExpandActiveLog")
}

extension View {
    /// Marks which pane / row currently holds the keyboard focus with a slim
    /// accent bar on the leading edge — the convention used by Mail, Xcode and
    /// VS Code for the "active" region. Deliberately not a full border: a boxed
    /// 2px ring around a big pane reads like a debug overlay.
    @ViewBuilder
    func paneFocusRing(_ active: Bool) -> some View {
        self.overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(active ? Theme.accent : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 5)
                .allowsHitTesting(false)
                .motion(.smooth(duration: 0.15), value: active)
        }
    }
}
