import SwiftUI

/// Inline partition detail used inside the right-hand Inspector — same data
/// the old standalone `PartitionsView` showed: per-node table + scontrol
/// key/value grid.
struct PartitionDetailsCard: View {
    let partition: String
    let nodes: [PartitionNode]
    let details: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !nodes.isEmpty {
                nodesBlock
            }
            if !details.isEmpty {
                scontrolBlock
            } else if nodes.isEmpty {
                ProgressView().tint(Theme.accent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var nodesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nodes (\(nodes.count))")
                .font(.caption.bold())
                .foregroundColor(Theme.textSecondary)
            ForEach(nodes) { node in
                nodeRow(node)
            }
        }
    }

    private func nodeRow(_ node: PartitionNode) -> some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor(node.state)).frame(width: 7, height: 7)
            Text(node.name)
                .font(.caption.monospaced().bold())
                .foregroundColor(Theme.textPrimary)
            Text(node.state)
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(stateColor(node.state).opacity(0.18))
                .foregroundColor(stateColor(node.state))
                .clipShape(Capsule())
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(node.cpus) CPU")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                Text(memSummary(used: node.memoryMB - node.freeMemoryMB, total: node.memoryMB))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var scontrolBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("scontrol show partition")
                .font(.caption.bold())
                .foregroundColor(Theme.textSecondary)
            ForEach(details.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top) {
                    Text(key)
                        .font(.caption2.bold())
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    Text(details[key] ?? "")
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
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
