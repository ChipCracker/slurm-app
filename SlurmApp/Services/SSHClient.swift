import Foundation
@preconcurrency import Shout

enum SSHError: LocalizedError {
    case notConnected
    case commandFailed(String, Int32)
    case authenticationFailed(String)
    case connectionFailed(String)
    case unsupportedAuthMethod
    case hostKeyMismatch(expected: String, actual: String)

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
        case .hostKeyMismatch(let expected, let actual):
            return "Host-Key stimmt nicht überein – mögliche Man-in-the-Middle-Attacke. "
                 + "Verbindung aus Sicherheitsgründen abgebrochen.\n"
                 + "Erwartet: \(SSHClient.shortFingerprint(expected))\n"
                 + "Erhalten: \(SSHClient.shortFingerprint(actual))"
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
    // Mutable so the host-key fingerprint can be pinned after the first connect
    // (trust-on-first-use); only mutated via `pinFingerprint` before any
    // reconnect can run, then read-only on `queue`.
    private var creds: Credentials
    private let queue: DispatchQueue
    let host: String
    let username: String
    /// SHA-256 host-key fingerprint observed on the live connection. The caller
    /// pins this into the stored credentials on first connect.
    let connectedFingerprint: String?

    private init(session: SSH, creds: Credentials) {
        self.session = session
        self.creds = creds
        self.host = creds.host
        self.username = creds.username
        self.connectedFingerprint = session.hostKeyFingerprintSHA256
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

    /// Pin the host-key fingerprint into this client's credentials so subsequent
    /// reconnects within the same session also verify it. Called once by AppState
    /// after trust-on-first-use, before any reconnect can happen.
    func pinFingerprint(_ fingerprint: String) {
        queue.async { [self] in creds.hostFingerprint = fingerprint }
    }

    /// First 16 hex chars of a fingerprint for compact display in errors/UI.
    static func shortFingerprint(_ fp: String) -> String {
        fp.isEmpty ? "—" : "SHA256:" + String(fp.prefix(16)) + "…"
    }

    /// Open a fresh, authenticated libssh2 session for `creds`. Used both for
    /// the initial connect and for transparent reconnects after a dropped link.
    /// Verifies the server host key against the pinned fingerprint (TOFU) and
    /// hard-fails on a mismatch — closing the silent re-auth-against-impostor
    /// hole on every reconnect path.
    private static func makeSession(_ creds: Credentials) throws -> SSH {
        let session: SSH
        do {
            // Pass the 45s timeout into the initializer so it also bounds the TCP
            // connect and the libssh2 handshake (otherwise both wait forever and
            // a dead link hangs the serial SSH queue). Generous enough for slow
            // reads like sreport, but recovers from a black-holing network.
            session = try SSH(host: creds.host, port: Int32(creds.port), timeout: 45_000)
        } catch {
            throw SSHError.connectionFailed(error.localizedDescription)
        }
        // Host-key verification: once a fingerprint is pinned, a different key
        // means the endpoint changed (re-provisioned host — or an attacker).
        // Refuse before any credential/command is sent.
        if let expected = creds.hostFingerprint, !expected.isEmpty {
            let actual = session.hostKeyFingerprintSHA256 ?? ""
            guard actual == expected else {
                throw SSHError.hostKeyMismatch(expected: expected, actual: actual)
            }
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
        let errOutput: String
        do {
            (status, output, errOutput) = try session.captureWithError(command)
        } catch {
            // Only a *session/channel* failure lands here (a non-zero command
            // exit comes back as `status`, not a throw). Treat it as a dead
            // link: reconnect (may throw if the host is truly unreachable, or
            // SSHError.hostKeyMismatch if the key changed) and retry once.
            session = try SSHClient.makeSession(creds)
            (status, output, errOutput) = try session.captureWithError(command)
        }
        if status != 0 && output.isEmpty {
            // Surface the real stderr diagnostic instead of a blank "(empty)".
            let err = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.commandFailed(err.isEmpty ? "(empty)" : err, status)
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
    // NOTE: awk and sed are deliberately NOT here — both can execute arbitrary
    // commands (awk system()/"cmd"|getline, GNU sed `e`/`w`) and write files, so
    // they are not "read-only" primitives. `sort` stays but its file-writing
    // `-o` flag is rejected below. The app never builds awk/sed programs from
    // input, so nothing legitimate is lost.
    static let safePrefixes: [String] = [
        "echo", "hostname", "whoami",
        "cat", "tail", "head", "ls", "stat", "wc",
        "grep", "sort", "uniq", "tr", "cut",
        "true", "false",
        "squeue", "sinfo", "sacct", "sstat", "sreport",
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
        // Command substitution defeats the whole prefix check — a whitelisted
        // leading token can embed an arbitrary mutating command via $(…) or
        // backticks. Reject both (outside quotes).
        if containsCommandSubstitution(trimmed) { return false }
        let segments = splitPipeline(trimmed)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { seg in
            let s = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return false }
            guard safePrefixes.contains(where: { matchWordPrefix(s, prefix: $0) }) else { return false }
            // `sort -o FILE` / `sort --output=FILE` writes an arbitrary file.
            if matchWordPrefix(s, prefix: "sort") && mentionsSortOutput(s) { return false }
            return true
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

    /// True if the command contains `$(`, `${` or a backtick outside quotes —
    /// all of which can run an embedded command the prefix check never sees.
    /// (`${` is parameter expansion, not execution, but it can still smuggle
    /// values into a command and isn't needed by any read path, so reject it.)
    private static func containsCommandSubstitution(_ command: String) -> Bool {
        var inSingle = false, inDouble = false
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            // `$(…)` survives inside double quotes in a real shell, so only a
            // single-quoted region is treated as inert here.
            if !inSingle {
                if ch == "`" { return true }
                if ch == "$", i + 1 < chars.count, chars[i + 1] == "(" || chars[i + 1] == "{" {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    /// True if a `sort` segment uses its file-writing output flag.
    private static func mentionsSortOutput(_ segment: String) -> Bool {
        let tokens = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return tokens.contains { $0 == "-o" || $0.hasPrefix("-o") || $0.hasPrefix("--output") }
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
                // Newline and ';' and '|' all separate commands in the remote
                // shell — splitting on them stops a whitelisted leading token
                // from carrying a hidden mutating command on the next line.
                if ch == "|" || ch == ";" || ch == "\n" || ch == "\r" {
                    parts.append(current); current = ""; i = command.index(after: i); continue
                }
                if ch == "&" {
                    // Both `&&` and a single backgrounding `&` separate commands.
                    let next = command.index(after: i)
                    if next < command.endIndex && command[next] == "&" {
                        parts.append(current); current = ""; i = command.index(i, offsetBy: 2); continue
                    }
                    parts.append(current); current = ""; i = command.index(after: i); continue
                }
            }
            current.append(ch)
            i = command.index(after: i)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
