import SwiftUI

/// Glass modal content: every cluster user's GPU-hour ranking for a
/// user-selectable period. Drives its own SSH fetches via the SlurmService
/// provided by AppState.
struct GpuHoursSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.glassModalDismiss) private var dismiss

    @State private var rangePreset: RangePreset = .thisYear
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var entries: [GpuHoursEntry] = []
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.hairline)
            controls
            Divider().background(Theme.hairline)
            content
        }
        .background(rangeShortcuts)
        .task { await reload() }
        .onChange(of: rangePreset) { _, _ in Task { await reload() } }
    }

    /// `⌥←` and `⌥→` cycle through the segmented range picker.
    private var rangeShortcuts: some View {
        ZStack {
            Button { stepRange(by: -1) } label: { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button { stepRange(by: +1) } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: .option)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private func stepRange(by delta: Int) {
        let all = RangePreset.allCases
        guard let idx = all.firstIndex(of: rangePreset) else { return }
        let next = (idx + delta + all.count) % all.count
        rangePreset = all[next]
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.success.opacity(0.18)).frame(width: 48, height: 48)
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2)
                    .foregroundColor(Theme.success)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("GPU Hours")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(periodLabel)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button(action: { Task { await reload() } }) {
                Image(systemName: loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
            .disabled(loading)
            .help("Aktualisieren")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
            .keyboardShortcut(.cancelAction)
            .help("Schliessen (Esc)")
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    // MARK: – Period controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $rangePreset) {
                ForEach(RangePreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)

            if rangePreset == .custom {
                DatePicker("", selection: $customStart, displayedComponents: .date)
                    .labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker("", selection: $customEnd, displayedComponents: .date)
                    .labelsHidden()
                Button("Anwenden") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            TextField("Suche User", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    // MARK: – Content

    @ViewBuilder
    private var content: some View {
        if let err = error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(Theme.danger)
                Text(err)
                    .font(.callout.monospaced())
                    .foregroundColor(Theme.danger)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Erneut versuchen") { Task { await reload() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if loading && entries.isEmpty {
            ProgressView("Lade GPU-Hours…")
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text(search.isEmpty ? "Keine Daten für diesen Zeitraum" : "Kein User passend zu „\(search)\"")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    summaryHeader
                    LazyVStack(spacing: 4) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, entry in
                            row(rank: idx + 1, entry: entry)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
    }

    private var summaryHeader: some View {
        HStack {
            Text("\(filtered.count) Nutzer · \(Int(totalHours).formatted())h gesamt")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            if let me = appState.credentials?.username, let myEntry = entries.first(where: { $0.user == me }),
               let myRank = entries.firstIndex(where: { $0.user == me }) {
                Text("Du: #\(myRank + 1) · \(Int(myEntry.hours).formatted())h")
                    .font(.caption.bold())
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.bottom, 4)
    }

    private func row(rank: Int, entry: GpuHoursEntry) -> some View {
        let isMe = appState.credentials?.username == entry.user
        let ratio = entry.hours / max(maxHours, 1)
        return HStack(spacing: 12) {
            Text("\(rank).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(entry.user)
                .font(.callout.monospaced().weight(isMe ? .bold : .regular))
                .foregroundColor(isMe ? Theme.accent : Theme.textPrimary)
                .frame(width: 160, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isMe ? Theme.accent : Theme.success)
                        .frame(width: max(4, CGFloat(min(1, ratio)) * geo.size.width))
                }
            }
            .frame(height: 8)
            Text(Int(entry.hours).formatted() + " h")
                .font(.callout.monospacedDigit().bold())
                .foregroundColor(Theme.textPrimary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isMe ? Theme.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: – Derived

    private var filtered: [GpuHoursEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.user.localizedCaseInsensitiveContains(search) }
    }

    private var maxHours: Double { entries.first?.hours ?? 1 }
    private var totalHours: Double { entries.reduce(0) { $0 + $1.hours } }

    private var periodLabel: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        let (start, end) = currentRange
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    private var currentRange: (start: Date, end: Date) {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        switch rangePreset {
        case .last30Days:
            return (cal.date(byAdding: .day, value: -30, to: now) ?? now, now)
        case .last90Days:
            return (cal.date(byAdding: .day, value: -90, to: now) ?? now, now)
        case .last12Months:
            return (cal.date(byAdding: .month, value: -12, to: now) ?? now, now)
        case .thisYear:
            let y = cal.component(.year, from: now)
            let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? now
            let end = cal.date(from: DateComponents(year: y, month: 12, day: 31)) ?? now
            return (start, end)
        case .lastYear:
            let y = cal.component(.year, from: now) - 1
            let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? now
            let end = cal.date(from: DateComponents(year: y, month: 12, day: 31)) ?? now
            return (start, end)
        case .custom:
            return (customStart, customEnd)
        }
    }

    // MARK: – Fetch

    private func reload() async {
        guard let slurm = appState.slurm else {
            error = "Keine SSH-Verbindung."
            return
        }
        loading = true
        defer { loading = false }
        let (start, end) = currentRange
        do {
            let list = try await slurm.fetchGpuHours(start: start, end: end, topN: 0)
            self.entries = list
            self.error = nil
        } catch {
            self.error = error.localizedDescription
            self.entries = []
        }
    }
}

enum RangePreset: String, CaseIterable, Identifiable {
    case last30Days, last90Days, last12Months, thisYear, lastYear, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .last30Days:   "30 Tage"
        case .last90Days:   "90 Tage"
        case .last12Months: "12 Monate"
        case .thisYear:     "Dieses Jahr"
        case .lastYear:     "Letztes Jahr"
        case .custom:       "Custom…"
        }
    }
}
