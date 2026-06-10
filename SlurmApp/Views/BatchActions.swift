import SwiftUI

/// Batch-Aktionen auf der markierten Job-Menge — abgestimmt auf die slurm-tui
/// (Cancel/QoS/Partition), erweitert um Hold/Release/Requeue.
enum BatchAction: String, CaseIterable, Identifiable {
    case cancel, qos, partition, hold, release, requeue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cancel:    "Abbrechen"
        case .qos:       "QoS ändern"
        case .partition: "Partition ändern"
        case .hold:      "Zurückhalten"
        case .release:   "Freigeben"
        case .requeue:   "Neu einreihen"
        }
    }

    var symbol: String {
        switch self {
        case .cancel:    "xmark.circle"
        case .qos:       "rosette"
        case .partition: "square.grid.2x2"
        case .hold:      "pause.circle"
        case .release:   "play.circle"
        case .requeue:   "arrow.clockwise.circle"
        }
    }

    var isDestructive: Bool { self == .cancel }

    /// QoS/Partition brauchen einen Zielwert → Werte-Sheet statt Bestätigung.
    var needsValue: Bool { self == .qos || self == .partition }

    /// Welche Jobs sind für diese Aktion zulässig? Folgt den App-eigenen
    /// Single-Job-Regeln (siehe JobDetailView): nur eigene Jobs, QoS auch für
    /// laufende, Partition/Hold/Release nur pending.
    func isEligible(_ job: Job, me: String?) -> Bool {
        guard let me, job.user == me else { return false }
        switch self {
        case .cancel, .qos, .requeue:     return job.isRunning || job.isPending
        case .partition, .hold, .release: return job.isPending
        }
    }

    /// Verb für den Bestätigungsdialog (Aktionen ohne Wert).
    var confirmVerb: String {
        switch self {
        case .cancel:  "abbrechen"
        case .hold:    "zurückhalten"
        case .release: "freigeben"
        case .requeue: "neu einreihen"
        case .qos, .partition: ""
        }
    }
}

/// Payload für den Bestätigungsdialog (Aktionen ohne Wert).
struct BatchConfirmation: Identifiable {
    let action: BatchAction
    let jobs: [Job]
    var id: String { action.rawValue }
}

/// Sheet zur Auswahl eines Zielwerts (QoS bzw. Partition) für die Batch-Aktion.
/// Spiegelt `SubmitJobView`/`pillOrPicker`: Dropdown der verfügbaren Optionen,
/// Text-Eingabe als Fallback.
struct BatchValueSheet: View {
    let action: BatchAction
    let jobCount: Int
    let options: [String]
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String = ""
    @FocusState private var fieldFocused: Bool

    private var fieldLabel: String { action == .qos ? "QoS" : "Partition" }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        infoCard
                        valueCard
                        applyButton
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(action.title)
            .inlineNavTitle()
            .navBarBackground(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { fieldFocused = false }
                }
                #endif
            }
        }
        .onAppear { if value.isEmpty { value = options.first ?? "" } }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(fieldLabel) für \(jobCount) Job\(jobCount == 1 ? "" : "s")")
                .font(.headline).foregroundColor(Theme.textPrimary)
            Text("`scontrol update` wird je Job einzeln ausgeführt. Nicht zulässige Jobs werden übersprungen.")
                .font(.caption).foregroundColor(Theme.textSecondary)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var valueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Neuer Wert").font(.caption).foregroundColor(Theme.textSecondary)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { opt in
                        Button(opt) { value = opt }
                    }
                } label: {
                    HStack {
                        Text(value.isEmpty ? "Wählen…" : value)
                            .foregroundColor(value.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption).foregroundColor(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else {
                TextField(fieldLabel, text: $value)
                    .plainTextInput()
                    .focused($fieldFocused)
                    .padding(10)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundColor(Theme.textPrimary)
                    .font(.callout.monospaced())
            }
        }
        .cardStyle()
    }

    private var applyButton: some View {
        Button {
            onApply(value.trimmingCharacters(in: .whitespaces))
            dismiss()
        } label: {
            Label("Anwenden", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(canApply ? Theme.accent : Theme.surfaceElevated)
                .foregroundColor(canApply ? Theme.onAccent : Theme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!canApply)
    }

    private var canApply: Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && jobCount > 0
    }
}
