import SwiftUI

struct SubmitJobView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scriptPath: String = ""
    @State private var submitting = false
    @State private var result: String?
    @State private var isError = false
    @FocusState private var pathFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        info
                        pathCard
                        submitButton
                        if let r = result {
                            ErrorBanner(message: r, tint: isError ? Theme.danger : Theme.success)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Job einreichen")
            .inlineNavTitle()
            .navBarBackground(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { pathFocused = false }
                }
                #endif
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("sbatch <path>").font(.headline).foregroundColor(Theme.textPrimary)
            Text("Pfad zu einem Batch-Skript, das bereits auf kiz0 liegt. Es wird kein Skript hochgeladen.")
                .font(.caption).foregroundColor(Theme.textSecondary)
        }
        .cardStyle()
    }

    private var pathCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote-Pfad").font(.caption).foregroundColor(Theme.textSecondary)
            TextField("/nfs/scratch/.../train.sbatch", text: $scriptPath)
                .plainTextInput()
                .focused($pathFocused)
                .submitLabel(.go)
                .onSubmit { Task { await submit() } }
                .padding(10)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(Theme.textPrimary)
                .font(.callout.monospaced())
        }
        .cardStyle()
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack {
                if submitting { ProgressView().tint(.black) }
                Label("Einreichen", systemImage: "paperplane.fill")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(canSubmit ? Theme.accent : Theme.surfaceElevated)
            .foregroundColor(canSubmit ? .black : Theme.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!canSubmit || submitting)
    }

    private var canSubmit: Bool {
        !scriptPath.trimmingCharacters(in: .whitespaces).isEmpty &&
        appState.slurm != nil
    }

    private func submit() async {
        guard let slurm = appState.slurm else { return }
        submitting = true; defer { submitting = false }
        do {
            let response = try await slurm.submitScript(at: scriptPath)
            result = "✓ \(response)"
            isError = false
        } catch {
            result = "✗ \(error.localizedDescription)"
            isError = true
        }
    }
}
