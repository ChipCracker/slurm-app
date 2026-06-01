import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var credentials: Credentials?
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var slurm: SlurmService?

    init() {
        #if DEBUG
        // UI-Mock zum Layout-Testen ohne SSH: `SLURMIOS_UIMOCK=1` setzt den
        // Status auf „verbunden", die JobsView lädt dann statische Mock-Daten
        // (siehe JobsViewModel.loadMockIfRequested). Kein Netzwerk, kein Keychain.
        if ProcessInfo.processInfo.environment["SLURMIOS_UIMOCK"] == "1" {
            self.credentials = Credentials(
                host: "kiz0.in.ohmportal.de", port: 22, username: "witzlch88229",
                authMethod: .password, password: nil, privateKey: nil, passphrase: nil
            )
            self.connectionStatus = .connected
            return
        }
        #endif
        if let stored = try? KeychainStore.shared.loadCredentials() {
            self.credentials = stored
            Task { await self.connect(using: stored) }
        }
    }

    func connect(using creds: Credentials) async {
        connectionStatus = .connecting
        do {
            let client = try await SSHClient.connect(credentials: creds)
            self.slurm = SlurmService(client: client)
            self.credentials = creds
            try? KeychainStore.shared.saveCredentials(creds)
            self.connectionStatus = .connected
        } catch {
            self.connectionStatus = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await slurm?.shutdown()
        slurm = nil
        connectionStatus = .disconnected
    }

    func forgetCredentials() async {
        await disconnect()
        try? KeychainStore.shared.deleteCredentials()
        credentials = nil
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "nicht verbunden"
        case .connecting: return "verbinde…"
        case .connected: return "verbunden"
        case .failed(let msg): return "Fehler: \(msg)"
        }
    }
}
