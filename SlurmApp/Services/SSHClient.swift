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

/// Priorität eines Kommandos in der seriellen SSH-Queue. Ein bereits
/// laufendes Kommando kann nicht unterbrochen werden (libssh2), aber wartende
/// Poll-Kommandos werden von Nutzeraktionen überholt — ein scancel muss nicht
/// hinter einem ganzen Poll-Rückstau (srun/sstat/tail) anstehen.
enum SSHCommandPriority: Sendable {
    /// Hintergrund-Polls (Jobs ~10 s, GPU ~5 s, Logs, Quota) — FIFO.
    case poll
    /// Vom Nutzer ausgelöste Aktion (scancel, Hold, QoS-Änderung, sbatch, …) —
    /// wird vor alle noch nicht gestarteten Poll-Kommandos einsortiert.
    case userInitiated
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

    // Wartende Kommandos: kleine Prioritätsliste VOR der seriellen Queue.
    // Nutzeraktionen werden vor noch nicht gestartete Polls einsortiert
    // (FIFO innerhalb derselben Priorität). Zugriff nur unter `stateLock`.
    private var pendingCommands: [(priority: SSHCommandPriority, run: () -> Void)] = []
    // Sleep/Wake-Hinweis: die Session ist vermutlich tot — das nächste Kommando
    // baut sie zuerst neu auf, statt 45 s in den Timeout des halboffenen
    // Sockets zu laufen. Wird von außerhalb der Queue gesetzt (markLinkSuspect),
    // daher unter `stateLock`.
    private var linkSuspect = false
    private let stateLock = NSLock()

    // Outage-Backoff (nur auf `queue` berührt): nach einem fehlgeschlagenen
    // Reconnect schlagen wartende Kommandos sofort mit `.notConnected` fehl,
    // statt pro Kommando bis zu ~90 s (45 s Read-Timeout + 45 s Connect) auf
    // der seriellen Queue zu verbrennen. Fenster wächst exponentiell
    // 5 s → 60 s; der erste Erfolg oder ein expliziter `reconnect()` (Wake,
    // Nutzer-Retry) setzt es zurück.
    private var lastReconnectFailure: Date?
    private var reconnectCooldown: TimeInterval = SSHClient.reconnectCooldownBase
    private static let reconnectCooldownBase: TimeInterval = 5
    private static let reconnectCooldownMax: TimeInterval = 60

    /// Threadsicheres Cancel-Flag — von `withTaskCancellationHandler`
    /// (beliebiger Thread) gesetzt, vom Queue-Block vor dem Start gelesen.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

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
    func execute(_ command: String, priority: SSHCommandPriority = .poll) async throws -> String {
        try ReadOnlyGuard.assertSafe(command)
        return try await rawExecute(command, priority: priority)
    }

    /// Use for mutating commands (sbatch, scancel, scontrol update). Bypasses
    /// the read-only guard — callers must confirm intent.
    func executeWrite(_ command: String, priority: SSHCommandPriority = .userInitiated) async throws -> String {
        try await rawExecute(command, priority: priority)
    }

    private func rawExecute(_ command: String, priority: SSHCommandPriority) async throws -> String {
        // Strukturierte Cancellation bis in die serielle Queue durchreichen:
        // Ein abgebrochener SwiftUI-Task (geschlossenes Sheet, weggetippte
        // Auswahl) darf sein bereits eingereihtes Kommando nicht mehr starten —
        // sonst blockieren z. B. mehrere abgebrochene sreport-Läufe minutenlang
        // alle Polls und Nutzeraktionen hinter sich.
        try Task.checkCancellation()
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                enqueue(priority: priority) { [self] in
                    // Eingereiht, aber noch nicht gestartet → überspringen.
                    guard !cancelled.isSet else {
                        cont.resume(throwing: CancellationError())
                        return
                    }
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
        } onCancel: {
            cancelled.set()
        }
    }

    /// Reiht `run` in die Pending-Liste ein und stößt die serielle Queue an.
    /// Pro `queue.async`-Tick wird genau ein Pending-Eintrag ausgeführt — die
    /// Anzahl der Ticks entspricht der Anzahl der Einträge, nur die
    /// Reihenfolge wird von der Priorität bestimmt.
    private func enqueue(priority: SSHCommandPriority, run: @escaping () -> Void) {
        stateLock.lock()
        switch priority {
        case .userInitiated:
            // Hinter bereits wartende Nutzeraktionen, vor alle Polls.
            let idx = pendingCommands.firstIndex { $0.priority == .poll } ?? pendingCommands.count
            pendingCommands.insert((priority, run), at: idx)
        case .poll:
            pendingCommands.append((priority, run))
        }
        stateLock.unlock()
        queue.async { [self] in
            stateLock.lock()
            let next = pendingCommands.isEmpty ? nil : pendingCommands.removeFirst()
            stateLock.unlock()
            next?.run()
        }
    }

    /// Markiert die Verbindung als vermutlich tot (Mac geht schlafen / ist
    /// gerade aufgewacht). Threadsicher und nicht blockierend — bewusst NICHT
    /// über die serielle Queue, damit der Hinweis auch ein bereits
    /// eingereihtes Poll-Kommando noch vor dessen Start erreicht.
    func markLinkSuspect() {
        stateLock.lock(); linkSuspect = true; stateLock.unlock()
    }

    private func consumeLinkSuspect() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let v = linkSuspect
        linkSuspect = false
        return v
    }

    /// Runs `command` on the current session. If the session itself errors
    /// (e.g. "Unable to send channel-open request" after the link dropped on
    /// sleep/idle/network change), the connection is dead — rebuild it once and
    /// retry the command so callers self-heal instead of failing forever.
    /// MUST be called on `queue`.
    private func captureWithReconnect(_ command: String) throws -> String {
        if consumeLinkSuspect() {
            // Sleep/Wake: Session proaktiv neu aufbauen, statt erst auf dem
            // halboffenen Socket in den 45-s-Timeout zu laufen.
            try rebuildSession()
        } else if let last = lastReconnectFailure {
            guard Date().timeIntervalSince(last) >= reconnectCooldown else {
                // Cool-down: Der Link ist bekannt tot — sofort scheitern, statt
                // die serielle Queue mit weiteren 45–90-s-Versuchen zu sättigen
                // (jedes wartende Kommando würde sonst denselben vollen
                // Timeout-Zyklus wiederholen).
                throw SSHError.notConnected
            }
            // Cool-down abgelaufen: Die alte Session ist bekannt tot — direkt
            // neu verbinden, statt erst 45 s auf dem toten Socket zu warten.
            try rebuildSession()
        }
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
            try rebuildSession()
            (status, output, errOutput) = try session.captureWithError(command)
        }
        if status != 0 && output.isEmpty {
            // Surface the real stderr diagnostic instead of a blank "(empty)".
            let err = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.commandFailed(err.isEmpty ? "(empty)" : err, status)
        }
        return output
    }

    /// Baut die Session neu auf und pflegt das Backoff-Fenster: Erfolg setzt
    /// es zurück, ein Fehlschlag startet bzw. verdoppelt den Cool-down
    /// (5 s → 60 s), in dem `captureWithReconnect` sofort mit `.notConnected`
    /// scheitert. Bei Fehlschlag bleibt die alte Session erhalten.
    /// MUST be called on `queue`.
    private func rebuildSession() throws {
        do {
            session = try SSHClient.makeSession(creds)
            lastReconnectFailure = nil
            reconnectCooldown = SSHClient.reconnectCooldownBase
        } catch {
            if lastReconnectFailure != nil {
                reconnectCooldown = min(reconnectCooldown * 2, SSHClient.reconnectCooldownMax)
            } else {
                reconnectCooldown = SSHClient.reconnectCooldownBase
            }
            lastReconnectFailure = Date()
            throw error
        }
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
                // Expliziter Retry/Wake: Suspect-Flag und Outage-Backoff
                // zurücksetzen, dann sofort versuchen. Best-effort — schlägt
                // der Aufbau fehl, bleibt die alte Session und das
                // Cool-down-Fenster greift wieder.
                _ = consumeLinkSuspect()
                lastReconnectFailure = nil
                reconnectCooldown = SSHClient.reconnectCooldownBase
                try? rebuildSession()
                cont.resume()
            }
        }
    }

    func ping() async throws -> String {
        try await rawExecute(
            "echo slurm-ios-ok; hostname; squeue --version 2>/dev/null || true",
            priority: .userInitiated
        )
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
