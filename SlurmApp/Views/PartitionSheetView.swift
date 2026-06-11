import SwiftUI

/// Big "liquid glass" sheet for partition deep-dives. The glass itself comes
/// from the presenting `GlassPanel` (native Liquid Glass on macOS 26+/iOS 26,
/// legacy frost on macOS 14/15); the content inside stays on opaque
/// `Theme.surface` cards — per HIG no glass-on-glass stacking.
struct PartitionSheetView: View {
    let partition: String
    let usage: PartitionUsage?
    let nodes: [PartitionNode]
    let details: [String: String]
    let onClose: () -> Void
    let onRefresh: () -> Void

    @EnvironmentObject private var appState: AppState
    /// Nodes whose detailed `scontrol show node` panel is expanded.
    @State private var expanded: Set<String> = []
    /// Cached per-node `scontrol show node` key/values.
    @State private var nodeDetails: [String: [String: String]] = [:]
    // Set, not a single slot: expanding two nodes quickly used to clobber each
    // other's spinner (the first's defer cleared the shared flag).
    @State private var loadingNodes: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(Theme.hairline)
            ScrollView {
                VStack(spacing: 16) {
                    if let u = usage {
                        allocationHero(u)
                    }
                    if !nodes.isEmpty {
                        nodesCard
                    }
                    if !details.isEmpty {
                        scontrolCard
                    }
                    if nodes.isEmpty && details.isEmpty {
                        SlurmyLoadingState(caption: "Lade Partition-Details…")
                            .padding(.vertical, 60)
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Partition")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(partition)
                    .font(.largeTitle.bold().monospaced())
                    .foregroundStyle(.primary)
            }
            Spacer()
            SlurmyGlassButtonGroup {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .slurmyGlassCircleButton()
                .help("Aktualisieren")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .slurmyGlassCircleButton()
                .keyboardShortcut(.cancelAction)
                .help("Schliessen (Esc)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: – Allocation hero

    private func allocationHero(_ u: PartitionUsage) -> some View {
        let gpu = GpuSpecs.info(partition: partition, gresType: u.gpuType)
        let totalCpus = nodes.reduce(0) { $0 + (Int($1.cpus) ?? 0) }
        let totalMemGB = nodes.reduce(0) { $0 + $1.memoryMB } / 1024
        return VStack(alignment: .leading, spacing: 12) {
            // GPUs allocated / total + %.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(u.allocatedGpus)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.utilizationColor(u.ratio))
                Text("/ \(u.totalGpus) GPUs belegt")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", u.ratio * 100))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundColor(Theme.utilizationColor(u.ratio))
            }
            // Full GPU model + VRAM (incl. memory type).
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill").foregroundColor(Theme.purple)
                Text(gpu.model)
                    .font(.headline)
                    .foregroundColor(Theme.purple)
                if let vram = gpu.vram {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(vram) VRAM")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            StackedGpuBar(usage: u)
                .frame(height: 14)
            // Nodes / CPUs / RAM aggregate.
            HStack(spacing: 18) {
                aggStat("server.rack", "\(nodes.count)", "Nodes")
                aggStat("cpu", "\(totalCpus)", "CPUs")
                aggStat("memorychip", "\(totalMemGB) GB", "RAM")
                Spacer()
            }
            Divider().background(Theme.hairline)
            HStack(spacing: 18) {
                metric("\(u.ownAllocated)", "mine", Theme.ownNonPreempt)
                metric("\(u.preemptible)", "preemptible", Theme.ownPreempt)
                metric("\(u.otherAllocated)", "other", Theme.otherNonPreempt)
                metric("\(u.availableGpus)", "frei", Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        // Opake Content-Karte — auf dem nativen Glas-Panel kein Material mehr
        // (Glas-auf-Glas), siehe HIG.
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(value).font(.callout.bold().monospacedDigit()).foregroundStyle(.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func aggStat(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold().monospacedDigit()).foregroundStyle(.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: – Nodes

    private var nodesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Nodes", count: nodes.count, symbol: "server.rack")
            VStack(spacing: 8) {
                ForEach(nodes) { node in
                    VStack(spacing: 0) {
                        nodeRow(node)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleNode(node.name) }
                        if expanded.contains(node.name) {
                            nodeDetailBlock(node)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: expanded)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
    }

    private func nodeRow(_ node: PartitionNode) -> some View {
        let gpu = parseGres(node.gres)
        return HStack(spacing: 12) {
            Circle().fill(stateColor(node.state)).frame(width: 9, height: 9)
            Text(node.name)
                .font(.callout.monospaced().bold())
                .foregroundStyle(.primary)
                .frame(width: 100, alignment: .leading)
            Text(node.state)
                .font(.caption.bold())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(stateColor(node.state).opacity(0.18), in: Capsule())
                .foregroundColor(stateColor(node.state))
            // GPUs of this node, prominent — "8× A100" or a muted "— GPU".
            if gpu.count > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "cpu.fill").font(.caption2)
                    Text("\(gpu.count)×").font(.caption.bold().monospacedDigit())
                    if let type = gpu.type {
                        Text(type.uppercased()).font(.caption.bold().monospaced())
                        if let vram = GpuSpecs.vramLabel(for: type) {
                            Text("· \(vram)").font(.caption2.monospaced()).opacity(0.8)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.purple.opacity(0.18), in: Capsule())
                .foregroundColor(Theme.purple)
            } else {
                Text("— GPU")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(node.cpus) CPU")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(memSummary(used: node.memoryMB - node.freeMemoryMB, total: node.memoryMB)) · \(gbStr(node.freeMemoryMB)) frei")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded.contains(node.name) ? 90 : 0))
                .help("GPU-Details ein-/ausblenden")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Parse a node GRES string ("gpu:a100:8(S:0-1)", "gpu:8", "(null)") into a
    /// GPU count and optional type.
    private func parseGres(_ gres: String) -> (count: Int, type: String?) {
        guard !gres.isEmpty, gres != "(null)", gres.lowercased().contains("gpu") else {
            return (0, nil)
        }
        // gpu:<type>:<count> first, then plain gpu:<count>.
        if let r = gres.range(of: #"gpu:([^:(]+):(\d+)"#, options: .regularExpression) {
            let seg = gres[r].split(separator: ":")   // ["gpu", type, count]
            if seg.count == 3, let n = Int(seg[2]) { return (n, String(seg[1])) }
        }
        if let r = gres.range(of: #"gpu:(\d+)"#, options: .regularExpression) {
            let seg = gres[r].split(separator: ":")
            if seg.count == 2, let n = Int(seg[1]) { return (n, nil) }
        }
        return (0, nil)
    }

    private func gbStr(_ mb: Int) -> String {
        String(format: "%.0f GB", Double(mb) / 1024)
    }

    // MARK: – Per-node detail (scontrol show node)

    private func toggleNode(_ name: String) {
        if expanded.contains(name) {
            expanded.remove(name)
        } else {
            expanded.insert(name)
            if nodeDetails[name] == nil { Task { await fetchNode(name) } }
        }
    }

    private func fetchNode(_ name: String) async {
        guard let slurm = appState.slurm else { return }
        loadingNodes.insert(name)
        defer { loadingNodes.remove(name) }
        if let d = try? await slurm.fetchNodeDetails(name) {
            nodeDetails[name] = d
        }
    }

    @ViewBuilder
    private func nodeDetailBlock(_ node: PartitionNode) -> some View {
        let d = nodeDetails[node.name]
        VStack(alignment: .leading, spacing: 12) {
            Divider().background(Theme.hairline)
            if d == nil && loadingNodes.contains(node.name) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lade scontrol show node…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let d {
                gpuDetailSection(d)
                resourceGrid(d)
                DisclosureGroup {
                    LazyVGrid(
                        columns: [GridItem(.fixed(150), alignment: .topLeading),
                                  GridItem(.flexible(), alignment: .topLeading)],
                        alignment: .leading, spacing: 6
                    ) {
                        ForEach(d.keys.sorted(), id: \.self) { key in
                            Text(key).font(.caption2.bold().monospaced()).foregroundStyle(.secondary)
                            Text(d[key] ?? "").font(.caption2.monospaced()).foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Alle Felder (\(d.count))").font(.caption.bold()).foregroundStyle(.secondary)
                }
            } else {
                Text("Keine Details verfügbar").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 12)
    }

    /// Prominent GPU section parsed from scontrol's Gres / GresUsed.
    private func gpuDetailSection(_ d: [String: String]) -> some View {
        let cfg = parseGres(d["Gres"] ?? "")
        let used = parseGresUsed(d["GresUsed"] ?? "")
        let free = max(0, cfg.count - used.count)
        let info = GpuSpecs.info(partition: partition, gresType: cfg.type)
        return VStack(alignment: .leading, spacing: 6) {
            Label("GPU", systemImage: "cpu.fill")
                .font(.caption.bold()).foregroundColor(Theme.purple)
            if cfg.count > 0 {
                HStack(spacing: 8) {
                    Text("\(cfg.count)× \(info.model)")
                        .font(.callout.bold()).foregroundStyle(.primary)
                    if let vram = info.vram {
                        Text("· \(vram) VRAM").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    gpuBadge("\(used.count) belegt", Theme.otherNonPreempt)
                    if !used.indices.isEmpty {
                        Text("IDX \(used.indices)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    gpuBadge("\(free) frei", Theme.gpuFree)
                }
            } else {
                Text("Keine GPUs auf diesem Knoten").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Key resource fields, prominent. Falls back to the per-node columns when a
    /// field is absent.
    private func resourceGrid(_ d: [String: String]) -> some View {
        let rows: [(String, String)] = [
            ("State", d["State"]),
            ("CfgTRES", d["CfgTRES"]),
            ("AllocTRES", d["AllocTRES"]),
            ("CPUs", [d["CPUAlloc"], d["CPUTot"]].compactMap { $0 }.joined(separator: " / ")),
            ("RealMemory", d["RealMemory"].map { "\($0) MB" }),
            ("FreeMem", d["FreeMem"].map { "\($0) MB" }),
        ].compactMap { (k, v) in (v?.isEmpty == false) ? (k, v!) : nil }
        return LazyVGrid(
            columns: [GridItem(.fixed(110), alignment: .topLeading),
                      GridItem(.flexible(), alignment: .topLeading)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(rows, id: \.0) { row in
                Text(row.0).font(.caption.bold().monospaced()).foregroundStyle(.secondary)
                Text(row.1).font(.caption.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
            }
        }
    }

    private func gpuBadge(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Allocated GPU count + indices from "gpu:rtx:1(IDX:0)" / "gpu:1(IDX:0-1)".
    private func parseGresUsed(_ s: String) -> (count: Int, indices: String) {
        let count = parseGres(s).count
        var idx = ""
        if let r = s.range(of: #"IDX:([0-9,\-]+)"#, options: .regularExpression) {
            idx = String(s[r]).replacingOccurrences(of: "IDX:", with: "")
        }
        return (count, idx)
    }

    // MARK: – scontrol

    private var scontrolCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "scontrol show partition", count: details.count, symbol: "doc.text.magnifyingglass")
            LazyVGrid(
                columns: [
                    GridItem(.fixed(160), alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(details.keys.sorted(), id: \.self) { key in
                    Text(key)
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(.secondary)
                    Text(details[key] ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
    }

    // MARK: – Helpers

    private func sectionHeader(title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(Theme.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("(\(count))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func memSummary(used: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        let usedGB = Double(used) / 1024
        let totalGB = Double(total) / 1024
        return String(format: "%.0f/%.0f GB", usedGB, totalGB)
    }

    private func stateColor(_ s: String) -> Color {
        switch s.lowercased() {
        case "idle":             return Theme.success
        case "mixed", "alloc",
             "allocated":        return Theme.warning
        case "down", "drain",
             "drained",
             "fail", "fail*",
             "down*":            return Theme.danger
        case "unknown":          return Theme.textSecondary
        default:                 return Theme.cyan
        }
    }
}
