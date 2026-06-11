import SwiftUI

/// Cross-partition node overview: every compute node in the cluster with its
/// GPUs, state, partitions, CPUs and free memory. The app-wide answer to the
/// slurm-tui per-partition `g` view — here all nodes at once, with a summary.
struct NodesOverviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.glassModalDismiss) private var dismiss

    @State private var nodes: [ClusterNode] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var gpuOnly = false
    /// GPU (count, type) resolved ONCE per node at load time. `ClusterNode.gpu`
    /// parses the GRES string with a regex on every access; without this cache
    /// the sort/filter ran that regex O(n log n) times on every keystroke.
    @State private var gpuCache: [String: (count: Int, type: String?)] = [:]

    private func gpu(_ node: ClusterNode) -> (count: Int, type: String?) {
        gpuCache[node.name] ?? (0, nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.hairline)
            summaryBar
            Divider().background(Theme.hairline)
            controls
            Divider().background(Theme.hairline)
            content
        }
        .task { await reload() }
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18)).frame(width: 48, height: 48)
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Cluster")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("Knoten")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
            }
            Spacer()
            SlurmyGlassButtonGroup {
                Button(action: { Task { await reload() } }) {
                    Image(systemName: loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.title3).frame(width: 32, height: 32)
                }
                .slurmyGlassCircleButton()
                .disabled(loading).help("Aktualisieren")

                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.title3).frame(width: 32, height: 32)
                }
                .slurmyGlassCircleButton()
                .keyboardShortcut(.cancelAction).help("Schliessen (Esc)")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    // MARK: – Summary

    private var summaryBar: some View {
        let gpuNodes = nodes.filter { gpu($0).count > 0 }
        let totalGpus = gpuNodes.reduce(0) { $0 + gpu($1).count }
        let types = Set(gpuNodes.compactMap { gpu($0).type?.uppercased() }).sorted()
        return HStack(spacing: 18) {
            stat("\(nodes.count)", "Knoten")
            stat("\(gpuNodes.count)", "mit GPU")
            stat("\(totalGpus)", "GPUs" + (types.isEmpty ? "" : " (\(types.joined(separator: ", ")))"))
            Spacer()
            stateCounts
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stateCounts: some View {
        let buckets = Dictionary(grouping: nodes) { stateBucket($0.state) }
        return HStack(spacing: 12) {
            ForEach(["idle", "mixed", "alloc", "down"], id: \.self) { key in
                if let c = buckets[key]?.count, c > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(stateColor(key)).frame(width: 8, height: 8)
                        Text("\(c) \(key)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: – Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $gpuOnly) { Text("Nur GPU-Knoten").font(.callout) }
                .toggleStyle(.switch)
            Spacer()
            TextField("Suche Knoten / Partition", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    // MARK: – Content

    @ViewBuilder
    private var content: some View {
        if let err = error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(Theme.danger)
                Text(err).font(.callout.monospaced()).foregroundColor(Theme.danger)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                Button("Erneut versuchen") { Task { await reload() } }
                    .slurmyGlassButton()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else if loading && nodes.isEmpty {
            SlurmyLoadingState(caption: "Lade Knoten…")
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text(search.isEmpty ? "Keine Knoten" : "Kein Knoten passend zu „\(search)\"")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { node in row(node) }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
    }

    private func row(_ node: ClusterNode) -> some View {
        let gpu = gpu(node)
        return HStack(spacing: 12) {
            Circle().fill(stateColor(stateBucket(node.state))).frame(width: 9, height: 9)
            Text(node.name)
                .font(.callout.monospaced().bold()).foregroundStyle(.primary)
                .frame(width: 120, alignment: .leading)
            Text(node.state)
                .font(.caption.bold())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(stateColor(stateBucket(node.state)).opacity(0.18), in: Capsule())
                .foregroundColor(stateColor(stateBucket(node.state)))
            if gpu.count > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "cpu.fill").font(.caption2)
                    Text("\(gpu.count)×").font(.caption.bold().monospacedDigit())
                    if let t = gpu.type {
                        Text(t.uppercased()).font(.caption.bold().monospaced())
                        if let vram = GpuSpecs.vramLabel(for: t) {
                            Text("· \(vram)").font(.caption2.monospaced()).opacity(0.8)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.purple.opacity(0.18), in: Capsule())
                .foregroundColor(Theme.purple)
            } else {
                Text("— GPU").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            if !node.partitions.isEmpty {
                Text(node.partitions.joined(separator: ","))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(node.cpus) CPU").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(gbStr(node.freeMemoryMB)) frei")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Opake Content-Zeile statt Material — kein Glas-auf-Glas im Modal.
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: – Derived

    private var filtered: [ClusterNode] {
        var list = nodes
        if gpuOnly { list = list.filter { gpu($0).count > 0 } }
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                $0.partitions.contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
        // GPU nodes first (most GPUs on top), then the rest by name. Reads the
        // cached count — no regex in the comparator.
        return list.sorted {
            let g0 = gpu($0).count, g1 = gpu($1).count
            if g0 != g1 { return g0 > g1 }
            return $0.name < $1.name
        }
    }

    private func gbStr(_ mb: Int) -> String { String(format: "%.0f GB", Double(mb) / 1024) }

    /// Collapse Slurm's many node states into the four legend buckets.
    private func stateBucket(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("idle") { return "idle" }
        if l.contains("mix") { return "mixed" }
        if l.contains("alloc") { return "alloc" }
        if l.contains("down") || l.contains("drain") || l.contains("fail") || l.contains("err") { return "down" }
        return "mixed"
    }

    private func stateColor(_ bucket: String) -> Color {
        switch bucket {
        case "idle":  return Theme.success
        case "mixed", "alloc": return Theme.warning
        case "down":  return Theme.danger
        default:      return Theme.cyan
        }
    }

    // MARK: – Fetch

    private func reload() async {
        guard let slurm = appState.slurm else { error = "Keine SSH-Verbindung."; return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await slurm.fetchAllNodes()
            // Resolve each node's GPU once here (regex), then serve from the
            // cache in the hot filter/sort paths.
            var cache: [String: (count: Int, type: String?)] = [:]
            for n in fetched { let g = n.gpu; cache[n.name] = (g.count, g.type) }
            nodes = fetched
            gpuCache = cache
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
