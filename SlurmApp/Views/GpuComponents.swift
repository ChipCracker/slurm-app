import SwiftUI

/// 1-line strip for the collapsed Inspector state: per-partition mini chips
/// (`p0 5/8` + thin stacked bar). Tapping anywhere on the strip should
/// re-open the full Inspector.
struct GpuAllocationMiniStrip: View {
    let usage: [PartitionUsage]
    var isLoading: Bool = false
    let onTap: () -> Void

    var body: some View {
        Group {
            if !usage.isEmpty {
                scroller(usage)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if isLoading {
                scroller(GpuAllocationStrip.skeletonUsage)
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .transition(.opacity)
            } else {
                EmptyView()
            }
        }
        .motion(.smooth(duration: 0.4), value: usage.isEmpty)
    }

    private func scroller(_ data: [PartitionUsage]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(data) { u in
                    chip(u)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .help("Inspector öffnen")
        // Die Tap-Geste allein ist für VoiceOver unsichtbar — Button-Trait +
        // explizite Aktion machen das Wieder-Öffnen des Inspectors zugänglich.
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("GPU-Auslastung")
        .accessibilityHint("Inspector öffnen")
        .accessibilityAction { onTap() }
    }

    private func chip(_ u: PartitionUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(u.partition)
                    .font(.caption.bold().monospaced())
                    .foregroundColor(Theme.textPrimary)
                Text("\(u.allocatedGpus)/\(u.totalGpus)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.utilizationColor(u.ratio))
            }
            StackedGpuBar(usage: u)
                .frame(width: 90, height: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 1-line strip for the collapsed Inspector state: per-filesystem mini chips
/// with used/quota percentage and a thin progress bar.
struct DiskQuotasMiniStrip: View {
    let quotas: [DiskQuota]
    var isLoading: Bool = false
    let onTap: () -> Void

    var body: some View {
        Group {
            if !quotas.isEmpty {
                scroller(quotas)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if isLoading {
                scroller(DiskQuotasCard.skeletonQuotas)
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .transition(.opacity)
            } else {
                EmptyView()
            }
        }
        .motion(.smooth(duration: 0.4), value: quotas.isEmpty)
    }

    private func scroller(_ data: [DiskQuota]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(data) { q in
                    chip(q)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .help("Inspector öffnen")
        // Siehe GpuAllocationMiniStrip: Trait + Aktion für VoiceOver.
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Disk-Quotas")
        .accessibilityHint("Inspector öffnen")
        .accessibilityAction { onTap() }
    }

    private func chip(_ q: DiskQuota) -> some View {
        let color = Theme.utilizationColor(q.usageRatio)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.caption2)
                    .foregroundColor(Theme.textSecondary)
                Text(shortFsMini(q.filesystem))
                    .font(.caption.monospaced())
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(String(format: "%.0f%%", q.usageRatio * 100))
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.background.opacity(0.6))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, CGFloat(q.usageRatio) * geo.size.width))
                }
            }
            .frame(width: 110, height: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func shortFsMini(_ s: String) -> String {
        // last two path components, e.g. "home/user"
        let stripped = s.split(separator: ":").last.map(String.init) ?? s
        let parts = stripped.split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }
}

/// Vertical column showing per-partition GPU allocation, split into four
/// buckets: own × non-preemptible/preemptible and other × non-preemptible/preemptible.
/// Mirrors the `slurm-tui` left-column block.
struct GpuAllocationStrip: View {
    let usage: [PartitionUsage]
    var isLoading: Bool = false
    /// Name of the partition that the keyboard cursor sits on — gets an
    /// accent border so the user can see which pill Space will toggle.
    var focusedPartition: String? = nil
    /// Invoked when the user taps a partition pill — the Inspector then
    /// opens a sheet with the per-node + scontrol details.
    var onSelect: ((String) -> Void)? = nil

    init(
        usage: [PartitionUsage],
        isLoading: Bool = false,
        focusedPartition: String? = nil,
        onSelect: ((String) -> Void)? = nil
    ) {
        self.usage = usage
        self.isLoading = isLoading
        self.focusedPartition = focusedPartition
        self.onSelect = onSelect
    }

    var body: some View {
        Group {
            if !usage.isEmpty {
                content(usage)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if isLoading {
                content(Self.skeletonUsage)
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .transition(.opacity)
            } else {
                EmptyView()
            }
        }
        .motion(.smooth(duration: 0.4), value: usage.isEmpty)
    }

    private func content(_ data: [PartitionUsage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Begriff deckungsgleich mit dem Dashboard-Widget („GPU-Belegung").
            Text("GPU-Belegung")
                .font(.caption.bold())
                .foregroundColor(Theme.textPrimary)
            ForEach(data) { u in
                // Echter Button statt onTapGesture: liefert den Button-Trait
                // und eine VoiceOver-Aktion — sonst wäre der Partition-Deep-Dive
                // für VoiceOver unerreichbar.
                Button {
                    onSelect?(u.partition)
                } label: {
                    GpuPartitionPill(usage: u)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paneFocusRing(focusedPartition == u.partition)
                .help("Partition-Details anzeigen")
                .accessibilityLabel("Partition \(u.partition): \(u.allocatedGpus) von \(u.totalGpus) GPUs belegt")
                .accessibilityHint("Öffnet Partition-Details")
            }
            GpuLegend()
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static let skeletonUsage: [PartitionUsage] = (0..<4).map { i in
        PartitionUsage(
            partition: "p\(i)",
            gpuType: "a100",
            totalGpus: 8,
            ownNonPreemptible: 2,
            ownPreemptible: 1,
            otherNonPreemptible: 3,
            otherPreemptible: 1
        )
    }
}

struct GpuPartitionPill: View {
    let usage: PartitionUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(usage.partition)
                    .font(.callout.bold())
                    .foregroundColor(Theme.textPrimary)
                Text(usage.gpuType.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.purple.opacity(0.18))
                    .foregroundColor(Theme.purple)
                    .clipShape(Capsule())
                Spacer(minLength: 0)
                Text("\(usage.allocatedGpus)/\(usage.totalGpus)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(Theme.utilizationColor(usage.ratio))
            }
            StackedGpuBar(usage: usage)
                .frame(height: 8)
            HStack(spacing: 8) {
                // One chip per non-zero bar segment, so the numbers never
                // overlap and add up to the total. 🔒 = garantiert, ⏏ = preemptierbar.
                ForEach(segmentLegend) { seg in
                    miniLegend(seg.label, count: seg.count, color: seg.color, symbol: seg.symbol)
                }
                Spacer(minLength: 0)
                miniLegend("frei", count: usage.availableGpus, color: Theme.gpuFree, symbol: Self.freeSymbol)
            }
            .help("🔒 = garantiert · ⏏ = preemptierbar (verdrängbar) · ◌ = frei")
        }
        .padding(10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// SF Symbols shared with the full legend so the coding stays consistent.
    static let guaranteedSymbol = "lock.fill"
    static let preemptSymbol = "eject.fill"
    static let freeSymbol = "circle.dashed"

    private struct LegendSeg: Identifiable {
        let label: String
        let count: Int
        let color: Color
        let symbol: String
        var id: String { "\(label)\(symbol)" }
    }

    /// Non-overlapping buckets matching the four bar segments, skipping zeros.
    private var segmentLegend: [LegendSeg] {
        var segs: [LegendSeg] = []
        if usage.ownNonPreemptible > 0 {
            segs.append(.init(label: "meine", count: usage.ownNonPreemptible, color: Theme.ownNonPreempt, symbol: Self.guaranteedSymbol))
        }
        if usage.ownPreemptible > 0 {
            segs.append(.init(label: "meine", count: usage.ownPreemptible, color: Theme.ownPreempt, symbol: Self.preemptSymbol))
        }
        if usage.otherNonPreemptible > 0 {
            segs.append(.init(label: "belegt", count: usage.otherNonPreemptible, color: Theme.otherNonPreempt, symbol: Self.guaranteedSymbol))
        }
        if usage.otherPreemptible > 0 {
            segs.append(.init(label: "belegt", count: usage.otherPreemptible, color: Theme.otherPreempt, symbol: Self.preemptSymbol))
        }
        return segs
    }

    private func miniLegend(_ label: String, count: Int, color: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.caption2)
                .foregroundColor(Theme.textSecondary)
                // Bei Platznot schrumpfen statt buchstabenweise umbrechen
                // (bis zu 5 Chips müssen in schmale Inspector-Breiten passen).
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 7))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

/// Stacked, 4-segment progress bar:
/// own·non-preempt | own·preempt | other·non-preempt | other·preempt | empty
struct StackedGpuBar: View {
    let usage: PartitionUsage

    var body: some View {
        GeometryReader { geo in
            let total = max(1, usage.totalGpus)
            let w = geo.size.width
            HStack(spacing: 0) {
                seg(width: segWidth(usage.ownNonPreemptible,   total: total, full: w), color: Theme.ownNonPreempt)
                seg(width: segWidth(usage.ownPreemptible,      total: total, full: w), color: Theme.ownPreempt)
                seg(width: segWidth(usage.otherNonPreemptible, total: total, full: w), color: Theme.otherNonPreempt)
                seg(width: segWidth(usage.otherPreemptible,    total: total, full: w), color: Theme.otherPreempt)
                Spacer(minLength: 0)
            }
            // The remaining (Spacer) area is free GPUs — tint it so "frei" is
            // visible at a glance instead of blending into the card.
            .background(Theme.gpuFree)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func segWidth(_ count: Int, total: Int, full: CGFloat) -> CGFloat {
        guard count > 0, total > 0 else { return 0 }
        return CGFloat(count) / CGFloat(total) * full
    }

    private func seg(width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
    }
}

/// Per-filesystem disk quota usage, mirrors slurm-tui's `disk_quota` widget.
struct DiskQuotasCard: View {
    let quotas: [DiskQuota]
    var isLoading: Bool = false

    var body: some View {
        Group {
            if !quotas.isEmpty {
                content(quotas)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if isLoading {
                content(Self.skeletonQuotas)
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .transition(.opacity)
            } else {
                content([])
                    .transition(.opacity)
            }
        }
        .motion(.smooth(duration: 0.4), value: quotas.isEmpty)
        .motion(.smooth(duration: 0.4), value: isLoading)
    }

    private func content(_ data: [DiskQuota]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disk-Quotas").font(.caption.bold()).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(data.count) FS").font(.caption2).foregroundColor(Theme.textSecondary)
            }
            if data.isEmpty {
                Text("keine Daten")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(data) { q in
                    quotaRow(q)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static let skeletonQuotas: [DiskQuota] = [
        DiskQuota(filesystem: "/home/user",        used: "9.6G",  quota: "20G",  limit: "22G", usedBytes: 10_307_921_510, quotaBytes: 21_474_836_480),
        DiskQuota(filesystem: "/scratch/user",     used: "240G",  quota: "500G", limit: "550G", usedBytes: 257_698_037_760, quotaBytes: 536_870_912_000),
        DiskQuota(filesystem: "/nfs1/scratch/user", used: "120G", quota: "300G", limit: "320G", usedBytes: 128_849_018_880, quotaBytes: 322_122_547_200),
    ]

    private func quotaRow(_ q: DiskQuota) -> some View {
        let color = Theme.utilizationColor(q.usageRatio)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(shortFs(q.filesystem))
                    .font(.caption.monospaced().bold())
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text("\(q.used) / \(q.quota)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.background.opacity(0.6))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, CGFloat(q.usageRatio) * geo.size.width))
                }
            }
            .frame(height: 5)
            HStack {
                Text(String(format: "%.0f%% belegt", q.usageRatio * 100))
                Spacer()
                Text("Limit \(q.limit)")
            }
            .font(.caption2)
            .foregroundColor(Theme.textSecondary)
        }
        .padding(8)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Shorten paths like `141.75.89.64:/mnt/mpatha/home/user` to
    /// `141.75.89.64:…/home/user`. Keeps the server/volume prefix and the last
    /// two path components, so two mounts ending in the same directory (e.g.
    /// `/scratch/user` vs. `/nfs1/scratch/user`) stay distinguishable.
    private func shortFs(_ s: String) -> String {
        let head = String(s.prefix(while: { $0 != "/" && $0 != ":" }))   // Server/Volume
        let path = s.dropFirst(head.count).drop(while: { $0 == ":" })
        let comps = path.split(separator: "/")
        // Schon kurz genug → unverändert anzeigen (inkl. evtl. Server-Präfix).
        guard comps.count > 2 else { return s }
        let tail = "/" + comps.suffix(2).joined(separator: "/")
        return head.isEmpty ? "…" + tail : head + ":…" + tail
    }
}

/// Compact GPU-Hours leaderboard, mirrors slurm-tui's left-column block.
struct GpuHoursCard: View {
    let entries: [GpuHoursEntry]
    let currentUser: String?
    var isLoading: Bool = false
    /// Inspector cursor lands on this card → accent border so the user
    /// sees that Space will open the full GPU-Hours sheet.
    var isFocused: Bool = false
    var onOpenFullView: (() -> Void)? = nil
    /// Manual refresh — GPU hours are otherwise only re-fetched every 30 min.
    var onRefresh: (() -> Void)? = nil

    private var maxHours: Double {
        entries.map(\.hours).max() ?? 1
    }

    var body: some View {
        Group {
            if !entries.isEmpty {
                content(entries)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if isLoading {
                content(Self.skeletonEntries)
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .transition(.opacity)
            } else {
                content([])
                    .transition(.opacity)
            }
        }
        .paneFocusRing(isFocused)
        .motion(.smooth(duration: 0.4), value: entries.isEmpty)
        .motion(.smooth(duration: 0.4), value: isLoading)
    }

    private func content(_ data: [GpuHoursEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Begriff deckungsgleich mit Dashboard-Widget und Voll-Sheet.
                Text("GPU-Stunden")
                    .font(.caption.bold())
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("Top \(data.count) · \(String(Calendar.current.component(.year, from: Date())))")
                    .font(.caption2)
                    .foregroundColor(Theme.textSecondary)
                if onOpenFullView != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                }
                if let onRefresh {
                    Button(action: onRefresh) {
                        Group {
                            if isLoading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.caption2)
                            }
                        }
                        // 44pt-Trefferfläche auf iOS: Das nackte caption2-Glyph
                        // (~14pt) liegt mitten auf der Karte, deren ganze Fläche
                        // das Voll-Sheet öffnet — knapp daneben getippt wirkte
                        // wie ein ignorierter Refresh.
                        .iosTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                    .disabled(isLoading)
                    .help("GPU-Stunden aktualisieren")
                }
            }
            if data.isEmpty {
                Text("keine Daten")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(Array(data.enumerated()), id: \.element.id) { idx, entry in
                    row(idx: idx + 1, entry: entry)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onOpenFullView?() }
        .help(onOpenFullView == nil ? "" : "Alle Nutzer + Zeitraum")
        // Kein Button-Wrap (die Karte enthält den Refresh-Button), aber
        // Trait + Aktion, damit VoiceOver das Voll-Sheet öffnen kann.
        .accessibilityAddTraits(onOpenFullView == nil ? [] : .isButton)
        .accessibilityHint(onOpenFullView == nil ? "" : "Öffnet alle Nutzer und die Zeitraum-Auswahl")
        .accessibilityAction { onOpenFullView?() }
    }

    static let skeletonEntries: [GpuHoursEntry] = (1...8).map { i in
        GpuHoursEntry(user: "user\(i)", hours: Double((9 - i) * 250))
    }

    private func row(idx: Int, entry: GpuHoursEntry) -> some View {
        let isMe = currentUser == entry.user
        let ratio = entry.hours / maxHours
        return HStack(spacing: 8) {
            Text(String(format: "%2d.", idx))
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.textSecondary)
                .frame(width: 22, alignment: .trailing)
            Text(entry.user)
                .font(.caption.monospaced())
                .foregroundColor(isMe ? Theme.accent : Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.background.opacity(0.6))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isMe ? Theme.accent : Theme.success)
                        .frame(width: max(2, CGFloat(min(1, ratio)) * geo.size.width))
                }
            }
            .frame(height: 6)
            Text("\(entry.hours.formatted(.number.precision(.fractionLength(0))))h")
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.textPrimary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

struct GpuLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                chip(color: Theme.ownNonPreempt, text: "meine", symbol: GpuPartitionPill.guaranteedSymbol)
                chip(color: Theme.ownPreempt, text: "meine", symbol: GpuPartitionPill.preemptSymbol)
                chip(color: Theme.otherNonPreempt, text: "belegt", symbol: GpuPartitionPill.guaranteedSymbol)
                chip(color: Theme.otherPreempt, text: "belegt", symbol: GpuPartitionPill.preemptSymbol)
                chip(color: Theme.gpuFree, text: "frei", symbol: GpuPartitionPill.freeSymbol)
                Spacer()
            }
            HStack(spacing: 10) {
                caption(GpuPartitionPill.guaranteedSymbol, "garantiert")
                caption(GpuPartitionPill.preemptSymbol, "preemptierbar")
                caption(GpuPartitionPill.freeSymbol, "frei")
            }
            .font(.caption2)
            .foregroundColor(Theme.textSecondary)
        }
    }

    private func chip(color: Color, text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.caption2)
                .foregroundColor(Theme.textSecondary)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func caption(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text("= \(text)")
        }
    }
}
