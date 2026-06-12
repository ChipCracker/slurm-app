import Foundation
import os

/// Central os.Logger handles so SSH/connection/parse failures are diagnosable in
/// the field (Console.app, `log stream --predicate 'subsystem == "…"'`) instead
/// of being swallowed by `try?`. Subsystem follows the bundle id so dev and prod
/// logs stay separate. Use `.error`/`.fault` for failures, `.debug` for noise.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "de.cwitzl.slurmapp"

    /// App lifecycle, connection state, credential persistence.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// SSH transport: connect, reconnect, host-key, command failures.
    static let ssh = Logger(subsystem: subsystem, category: "ssh")
    /// Parsing of Slurm command output.
    static let parse = Logger(subsystem: subsystem, category: "parse")
    /// Persistence (bookmarks, dashboard layout, preferences).
    static let store = Logger(subsystem: subsystem, category: "store")
}
