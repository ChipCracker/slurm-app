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
    @State private var loadingOptions = false
    /// Mindestens eine der beiden Listen kam leer zurück (Fetch fehlgeschlagen
    /// oder Cluster liefert nichts) — Hinweis zeigen statt leerer Picker.
    @State private var optionsLoadFailed = false

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
            // Kein opaker Nav-Bar-Hintergrund — System-Bar = Liquid Glass.
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
                optionPicker(selection: $partition, options: availablePartitions, prompt: "p2")
            }
            row(label: "QoS") {
                optionPicker(selection: $qos, options: availableQos, prompt: "interactive")
            }
            if optionsLoadFailed {
                Text("Optionen konnten nicht geladen werden – Werte manuell prüfen.")
                    .font(.caption)
                    .foregroundColor(Theme.warning)
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

    /// Picker mit den Cluster-Optionen; Spinner solange geladen wird und
    /// Freitextfeld als Fallback, wenn der Fetch nichts lieferte (statt eines
    /// leeren, unbedienbaren Pickers mit hartkodiertem Default).
    @ViewBuilder
    private func optionPicker(selection: Binding<String>, options: [String], prompt: String) -> some View {
        if !options.isEmpty {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        } else if loadingOptions {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Lade Optionen…")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        } else {
            TextField(prompt, text: selection)
                .plainTextInput()
                .frame(maxWidth: 160)
                .padding(6)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
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
                .foregroundColor(Theme.onAccent)
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
        guard appState.slurm != nil else {
            optionsLoadFailed = true
            return
        }
        loadingOptions = true
        defer { loadingOptions = false }
        // Verbindungsweiter Cache statt eigener SSH-Roundtrips: sacctmgr/sinfo
        // liefen sonst bei jedem Öffnen ('i') erneut über die serielle
        // libssh2-Queue und verzögerten den 10s-Job-Poll dahinter.
        let qosList = await appState.cachedAvailableQos()
        if !qosList.isEmpty {
            self.availableQos = qosList
            if !qosList.contains(self.qos) { self.qos = qosList.first ?? "interactive" }
        }
        let parts = await appState.cachedAvailablePartitions()
        if !parts.isEmpty {
            self.availablePartitions = parts
            if !parts.contains(self.partition) { self.partition = parts.first ?? "p2" }
        }
        optionsLoadFailed = qosList.isEmpty || parts.isEmpty
    }
}
