import Foundation
@preconcurrency import Shout

enum SSHError: LocalizedError {
    case notConnected
    case commandFailed(String, Int32)
    case authenticationFailed(String)
    case connectionFailed(String)
    case unsupportedAuthMethod

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Nicht verbunden."
        case .commandFailed(let msg, let code):
            return "Befehl fehlgeschlagen (rc=\(code)): \(msg)"
        case .authenticationFailed(let detail):
            return "Authentifizierung fehlgeschlagen: \(detail)"
        case .connectionFailed(let detail):
            return "Verbindung fehlgeschlagen: \(detail)"
        case .unsupportedAuthMethod:
            return "Auth-Methode wird nicht unterstützt."
        }
    }
}

/// macOS-only SSH wrapper backed by Shout (libssh2). Read-only by default;
/// mutating commands go through `executeWrite`.
///
/// libssh2 is **not** thread-safe per session — all calls are serialized on a
/// dedicated `DispatchQueue` so concurrent SwiftUI refresh tasks can never
/// touch the session in parallel.
final class SSHClient: @unchecked Sendable {
    // `session` is rebuilt on the serial `queue` when the connection dies
    // (sleep/wake, idle-timeout, network change), so it is mutable but only
    // ever touched from `queue`.
    private var session: SSH
    private let creds: Credentials
    private let queue: DispatchQueue
    let host: String
    let username: String

    private init(session: SSH, creds: Credentials) {
        self.session = session
        self.creds = creds
        self.host = creds.host
        self.username = creds.username
        self.queue = DispatchQueue(label: "slurmios.ssh.\(creds.username)@\(creds.host)", qos: .userInitiated)
    }

    static func connect(credentials creds: Credentials) async throws -> SSHClient {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SSHClient, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = try makeSession(creds)
                    cont.resume(returning: SSHClient(session: session, creds: creds))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Open a fresh, authenticated libssh2 session for `creds`. Used both for
    /// the initial connect and for transparent reconnects after a dropped link.
    private static func makeSession(_ creds: Credentials) throws -> SSH {
        let session: SSH
        do {
            session = try SSH(host: creds.host, port: Int32(creds.port))
            // Abort a stalled blocking call after 45s (LIBSSH2_ERROR_TIMEOUT)
            // instead of hanging the serial SSH queue forever — generous enough
            // for slow reads like sreport, but recovers from a dead network link.
            session.timeout = 45_000
        } catch {
            throw SSHError.connectionFailed(error.localizedDescription)
        }
        do {
            switch creds.authMethod {
            case .password:
                try session.authenticate(username: creds.username, password: creds.password ?? "")
            case .privateKey:
                guard let pem = creds.privateKey, !pem.isEmpty else {
                    throw SSHError.authenticationFailed("Privater Schlüssel fehlt.")
                }
                // In-Memory-Auth: kein Temp-File, keine .pub, kein getpass-
                // Fallback — funktioniert in der Sandbox.
                try session.authenticate(
                    username: creds.username,
                    privateKeyData: pem,
                    passphrase: (creds.passphrase?.isEmpty == false) ? creds.passphrase : nil
                )
            }
        } catch let e as SSHError {
            throw e
        } catch {
            // Shout.SSHError ist CustomStringConvertible und trägt die echte
            // libssh2-Meldung. Die NSError-Bridge würde nur das generische
            // "operation couldn't be completed" liefern.
            throw SSHError.authenticationFailed(String(describing: error))
        }
        return session
    }

    /// Whitelisted read-only command path.
    func execute(_ command: String) async throws -> String {
        try ReadOnlyGuard.assertSafe(command)
        return try await rawExecute(command)
    }

    /// Use for mutating commands (sbatch, scancel, scontrol update). Bypasses
    /// the read-only guard — callers must confirm intent.
    func executeWrite(_ command: String) async throws -> String {
        try await rawExecute(command)
    }

    private func rawExecute(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                do {
                    cont.resume(returning: try captureWithReconnect(command))
                } catch let err as SSHError {
                    cont.resume(throwing: err)
                } catch {
                    // Shout.SSHError is CustomStringConvertible and carries the
                    // real libssh2 message (e.g. "channel failure", "socket
                    // timeout"). `localizedDescription` would only bridge to the
                    // useless "The operation couldn't be completed.
                    // (Shout.SSHError error 1.)" — so describe it directly.
                    cont.resume(throwing: SSHError.commandFailed(String(describing: error), -1))
                }
            }
        }
    }

    /// Runs `command` on the current session. If the session itself errors
    /// (e.g. "Unable to send channel-open request" after the link dropped on
    /// sleep/idle/network change), the connection is dead — rebuild it once and
    /// retry the command so callers self-heal instead of failing forever.
    /// MUST be called on `queue`.
    private func captureWithReconnect(_ command: String) throws -> String {
        let status: Int32
        let output: String
        do {
            (status, output) = try session.capture(command)
        } catch {
            // Only a *session/channel* failure lands here (a non-zero command
            // exit comes back as `status`, not a throw). Treat it as a dead
            // link: reconnect (may throw if the host is truly unreachable) and
            // retry exactly once.
            session = try SSHClient.makeSession(creds)
            (status, output) = try session.capture(command)
        }
        if status != 0 && output.isEmpty {
            throw SSHError.commandFailed("(empty)", status)
        }
        return output
    }

    /// Proactively rebuild the session. Call when the link likely died while the
    /// app was away (background/sleep) so the next command starts on a fresh
    /// socket instead of blocking on a half-open one until the timeout. Runs on
    /// the queue (serialised after any in-flight command); best-effort — if the
    /// host is unreachable the old session is kept and the normal
    /// captureWithReconnect path retries later.
    func reconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let fresh = try? SSHClient.makeSession(creds) { session = fresh }
                cont.resume()
            }
        }
    }

    func ping() async throws -> String {
        try await rawExecute("echo slurm-ios-ok; hostname; squeue --version 2>/dev/null || true")
    }

    func close() async {
        // Shout's SSH closes on deinit; no explicit close required.
    }
}

/// Whitelist of safe (read-only) command prefixes. Mutating actions must use
/// `executeWrite` explicitly.
enum ReadOnlyGuard {
    static let safePrefixes: [String] = [
        "echo", "hostname", "whoami",
        "cat", "tail", "head", "ls", "stat", "wc",
        "grep", "awk", "sort", "uniq", "tr", "cut", "sed",
        "true", "false",
        "squeue", "sinfo", "sacct", "sreport",
        "sacctmgr show",
        "scontrol show",
        "scontrol write batch_script",
        "nvidia-smi --query", "nvidia-smi -q",
        "quota",
        "df",
    ]

    static func isSafe(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsRedirection(trimmed) { return false }
        let segments = splitPipeline(trimmed)
        return segments.allSatisfy { seg in
            let s = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            return safePrefixes.contains { matchWordPrefix(s, prefix: $0) }
        }
    }

    static func assertSafe(_ command: String) throws {
        if !isSafe(command) {
            throw SSHError.commandFailed("Command blocked by read-only guard: \(command)", -1)
        }
    }

    private static func matchWordPrefix(_ command: String, prefix: String) -> Bool {
        guard command.hasPrefix(prefix) else { return false }
        if command.count == prefix.count { return true }
        let next = command[command.index(command.startIndex, offsetBy: prefix.count)]
        return !(next.isLetter || next.isNumber || next == "_")
    }

    private static func containsRedirection(_ command: String) -> Bool {
        var inSingle = false, inDouble = false
        var i = command.startIndex
        while i < command.endIndex {
            let ch = command[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble && (ch == ">" || ch == "<") { return true }
            i = command.index(after: i)
        }
        return false
    }

    private static func splitPipeline(_ command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var i = command.startIndex
        var inSingle = false, inDouble = false
        while i < command.endIndex {
            let ch = command[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "|" || ch == ";" {
                    parts.append(current); current = ""; i = command.index(after: i); continue
                }
                if ch == "&", command.index(after: i) < command.endIndex, command[command.index(after: i)] == "&" {
                    parts.append(current); current = ""; i = command.index(i, offsetBy: 2); continue
                }
            }
            current.append(ch)
            i = command.index(after: i)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
