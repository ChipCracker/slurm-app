import SwiftUI

/// Compact form that builds a `srun --pty` command and launches it in
/// Terminal.app. Mirrors slurm-tui's `job_submit` interactive screen.
struct InteractiveSessionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var partition: String = "p2"
    @State private var gpus: Int = 1
    @State private var cpus: Int = 4
    @State private var memPerCpu: String = "4G"
    @State private var qos: String = "interactive"
    @State private var availablePartitions: [String] = []
    @State private var availableQos: [String] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        infoCard
                        formCard
                        previewCard
                        launchButton
                    }
                    .padding()
                }
            }
            .navigationTitle("Interaktive Session")
            .inlineNavTitle()
            .navBarBackground(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .task {
            await loadOptions()
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Öffnet Terminal.app").font(.headline).foregroundColor(Theme.textPrimary)
            Text("Die App führt selbst kein TTY. Der unten generierte `srun --pty` läuft in einer Terminal-Sitzung über SSH.")
                .font(.caption).foregroundColor(Theme.textSecondary)
        }
        .cardStyle()
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(label: "Partition") {
                Picker("", selection: $partition) {
                    ForEach(availablePartitions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            row(label: "QoS") {
                Picker("", selection: $qos) {
                    ForEach(availableQos, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            row(label: "GPUs") {
                Stepper("\(gpus)", value: $gpus, in: 0...8)
            }
            row(label: "CPUs") {
                Stepper("\(cpus)", value: $cpus, in: 1...64)
            }
            row(label: "Mem/CPU") {
                TextField("4G", text: $memPerCpu)
                    .plainTextInput()
                    .frame(maxWidth: 100)
                    .padding(6)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .cardStyle()
    }

    private func row<T: View>(label: String, @ViewBuilder content: () -> T) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            content()
            Spacer()
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vorschau").font(.caption.bold()).foregroundColor(Theme.textSecondary)
            CopyableText(text: srunCommand)
        }
        .cardStyle()
    }

    private var launchButton: some View {
        Button {
            launch()
        } label: {
            Label("In Terminal öffnen", systemImage: "terminal")
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accent)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(appState.credentials == nil)
    }

    private var srunCommand: String {
        "srun --qos=\(qos) --partition=\(partition) --gres=gpu:\(gpus) --cpus-per-task=\(cpus) --mem-per-cpu=\(memPerCpu) --pty bash -l"
    }

    private func launch() {
        guard let creds = appState.credentials else { return }
        TerminalLauncher.interactive(
            partition: partition,
            gpus: gpus,
            cpus: cpus,
            memoryPerCpu: memPerCpu,
            qos: qos,
            credentials: creds
        )
        dismiss()
    }

    private func loadOptions() async {
        guard let slurm = appState.slurm else { return }
        if let qos = try? await slurm.fetchAvailableQos(), !qos.isEmpty {
            self.availableQos = qos
            if !qos.contains(self.qos) { self.qos = qos.first ?? "interactive" }
        }
        if let parts = try? await slurm.fetchAvailablePartitions(), !parts.isEmpty {
            self.availablePartitions = parts
            if !parts.contains(self.partition) { self.partition = parts.first ?? "p2" }
        }
    }
}
