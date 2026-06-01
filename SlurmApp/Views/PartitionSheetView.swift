import SwiftUI

/// Big translucent "liquid glass" sheet for partition deep-dives.
/// Uses macOS Materials (`.ultraThinMaterial`) layered over a colored
/// gradient so the background of the host window subtly bleeds through —
/// matches the Tahoe-style sheet aesthetic.
struct PartitionSheetView: View {
    let partition: String
    let usage: PartitionUsage?
    let nodes: [PartitionNode]
    let details: [String: String]
    let onClose: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(.white.opacity(0.08))
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
                        ProgressView("Lade Partition-Details…")
                            .tint(Theme.accent)
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
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
            .help("Aktualisieren")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Circle())
            .keyboardShortcut(.cancelAction)
            .help("Schliessen (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: – Allocation hero

    private func allocationHero(_ u: PartitionUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(u.allocatedGpus)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.utilizationColor(u.ratio))
                Text("/ \(u.totalGpus) GPUs")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(u.gpuType.uppercased())
                    .font(.caption.bold().monospaced())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.purple.opacity(0.22), in: Capsule())
                    .foregroundColor(Theme.purple)
            }
            StackedGpuBar(usage: u)
                .frame(height: 14)
            HStack(spacing: 18) {
                metric("\(u.ownAllocated)", "mine", Theme.ownNonPreempt)
                metric("\(u.preemptible)", "preemptible", Theme.ownPreempt)
                metric("\(u.otherAllocated)", "other", Theme.otherNonPreempt)
                metric("\(u.availableGpus)", "frei", Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
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
                    nodeRow(node)
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func nodeRow(_ node: PartitionNode) -> some View {
        HStack(spacing: 12) {
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
            Text(gresShort(node.gres))
                .font(.caption.monospaced())
                .foregroundColor(Theme.purple)
                .lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(node.cpus) CPU")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(memSummary(used: node.memoryMB - node.freeMemoryMB, total: node.memoryMB))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func gresShort(_ gres: String) -> String {
        if gres.isEmpty || gres == "(null)" { return "no GPU" }
        return gres.split(separator: "(").first.map(String.init) ?? gres
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
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
