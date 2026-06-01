import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var pingResult: String?
    @State private var pinging = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        statusCard
                        pingCard
                        actions
                    }
                    .padding()
                }
            }
            .navigationTitle("Settings")
            .navBarBackground(Theme.background)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verbindung").font(.headline).foregroundColor(Theme.textPrimary)
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(appState.connectionStatus.label).foregroundColor(Theme.textSecondary)
                Spacer()
            }
            if let c = appState.credentials {
                Text("\(c.username)@\(c.host):\(c.port)")
                    .font(.caption.monospaced())
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .cardStyle()
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected:  return Theme.success
        case .connecting: return Theme.warning
        case .failed:     return Theme.danger
        case .disconnected: return Theme.textSecondary
        }
    }

    private var pingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SSH-Test").font(.headline).foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    Task { await ping() }
                } label: {
                    if pinging { ProgressView().tint(Theme.accent) }
                    else { Image(systemName: "antenna.radiowaves.left.and.right") }
                }
            }
            if let r = pingResult {
                let isErr = r.hasPrefix("✗")
                CopyableText(
                    text: r,
                    color: isErr ? Theme.danger : Theme.textPrimary,
                    iconColor: isErr ? Theme.danger : Theme.textSecondary
                )
            } else {
                Text("Tippt das Icon, um einen Verbindungstest auszuführen (echo + hostname).")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .cardStyle()
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await appState.disconnect() }
            } label: {
                Label("Trennen", systemImage: "link.badge.minus")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.surfaceElevated)
                    .foregroundColor(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button(role: .destructive) {
                Task { await appState.forgetCredentials() }
            } label: {
                Label("Zugangsdaten löschen", systemImage: "trash")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Theme.danger.opacity(0.18))
                    .foregroundColor(Theme.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func ping() async {
        guard let slurm = appState.slurm else {
            pingResult = "Keine Verbindung."
            return
        }
        pinging = true; defer { pinging = false }
        do {
            let txt = try await slurm.ping()
            pingResult = "✓ \(txt.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            pingResult = "✗ \(error.localizedDescription)"
        }
    }
}
