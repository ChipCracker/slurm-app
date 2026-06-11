import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var credentials: Credentials?
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var slurm: SlurmService? { didSet { cachedQos = nil; cachedPartitions = nil } }

    // Connection-wide caches for the cluster-static QoS / partition lists, so
    // JobsView batch actions and every JobDetailView don't each refetch them.
    // Cleared automatically whenever `slurm` changes (connect/disconnect).
    private var cachedQos: [String]?
    private var cachedPartitions: [String]?

    func cachedAvailableQos() async -> [String] {
        if let c = cachedQos { return c }
        let q = (try? await slurm?.fetchAvailableQos()) ?? []
        if !q.isEmpty { cachedQos = q }
        return q
    }

    func cachedAvailablePartitions() async -> [String] {
        if let c = cachedPartitions { return c }
        let p = (try? await slurm?.fetchAvailablePartitions()) ?? []
        if !p.isEmpty { cachedPartitions = p }
        return p
    }

    // GPU-hours cache keyed by period — the standalone GPU-hours sheet re-ran the
    // heavy year-long sreport on every open; this serves a recent result instead.
    private var gpuHoursCache: [String: (entries: [GpuHoursEntry], at: Date)] = [:]

    func cachedGpuHours(forKey key: String, maxAge: TimeInterval) -> [GpuHoursEntry]? {
        guard let c = gpuHoursCache[key], Date().timeIntervalSince(c.at) < maxAge else { return nil }
        return c.entries
    }

    func storeGpuHours(_ entries: [GpuHoursEntry], forKey key: String) {
        gpuHoursCache[key] = (entries, Date())
    }

    init() {
        #if DEBUG
        // UI-Mock zum Layout-Testen ohne SSH: `SLURMIOS_UIMOCK=1` setzt den
        // Status auf „verbunden", die JobsView lädt dann statische Mock-Daten
        // (siehe JobsViewModel.loadMockIfRequested). Kein Netzwerk, kein Keychain.
        if ProcessInfo.processInfo.environment["SLURMIOS_UIMOCK"] == "1" {
            self.credentials = Credentials(
                host: "cluster.example.com", port: 22, username: "demo",
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
            var creds = creds
            // Trust-on-first-use: pin the host-key fingerprint observed on this
            // first successful connect. From now on every connect/reconnect
            // verifies the live key against it and hard-fails on a mismatch.
            if creds.hostFingerprint == nil, let fp = client.connectedFingerprint {
                creds.hostFingerprint = fp
                client.pinFingerprint(fp)
            }
            self.credentials = creds
            do {
                try KeychainStore.shared.saveCredentials(creds)
            } catch {
                Log.app.error("Keychain-Speichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
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

    /// Called by the polling view models when a read/command fails at the
    /// connection level (the SSH layer reconnects transparently underneath, but
    /// persistent failure must be visible instead of the app still claiming
    /// "verbunden"). Only downgrades a currently-connected session.
    func reportConnectionTrouble(_ message: String) {
        guard slurm != nil else { return }
        if case .connected = connectionStatus {
            connectionStatus = .degraded(message)
        } else if case .degraded = connectionStatus {
            connectionStatus = .degraded(message)
        }
    }

    /// Called when a read/command succeeds, clearing a transient degraded state.
    func reportConnectionHealthy() {
        guard slurm != nil else { return }
        if case .degraded = connectionStatus {
            connectionStatus = .connected
        }
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    /// Connected once, but the latest command failed — link likely flapping.
    /// The SSH layer keeps retrying; this just makes the trouble glanceable.
    case degraded(String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "nicht verbunden"
        case .connecting: return "verbinde…"
        case .connected: return "verbunden"
        case .degraded: return "Verbindung instabil…"
        case .failed(let msg): return "Fehler: \(msg)"
        }
    }
}
