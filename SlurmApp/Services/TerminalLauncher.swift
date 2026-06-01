import Foundation
#if os(macOS)
import AppKit
#endif

/// Opens an external macOS Terminal window connected to the cluster via SSH
/// to run interactive Slurm commands. The app never speaks TTY itself —
/// `srun --pty`, `srun --overlap --pty bash` and a plain login shell are
/// delegated to Terminal.app where the user has a real PTY.
///
/// On iOS there is no Terminal.app and no PTY surface, so every entry point is
/// a no-op. Call sites hide the corresponding buttons via `#if os(macOS)`; the
/// stubs only guarantee the type compiles for the iOS slice.
enum TerminalLauncher {

    /// Open Terminal.app and have it run `ssh <host> <remoteCommand>`.
    /// If `remoteCommand` is nil, just opens an interactive SSH login.
    static func openSSH(host: String, user: String, port: Int = 22, remoteCommand: String? = nil) {
        #if os(macOS)
        let portFlag = port == 22 ? "" : "-p \(port) "
        let target = "\(user)@\(host)"
        let inner: String
        if let cmd = remoteCommand {
            // -t forces TTY allocation so srun --pty / overlapping bash work.
            inner = "ssh -t \(portFlag)\(target) \(escapeShellSingleQuoted(cmd))"
        } else {
            inner = "ssh \(portFlag)\(target)"
        }
        runInTerminal(inner)
        #endif
    }

    /// `srun --overlap --jobid=… --pty bash -l` — attaches to a running job's
    /// allocation. The job ID is normalised to its base form (array tasks
    /// share one allocation).
    static func attach(jobId: String, credentials: Credentials) {
        let baseId = jobId.split(separator: "_").first.map(String.init) ?? jobId
        let cmd = "srun --jobid=\(baseId) --overlap --pty bash -l"
        openSSH(
            host: credentials.host,
            user: credentials.username,
            port: credentials.port,
            remoteCommand: cmd
        )
    }

    /// Start a new interactive allocation in a fresh Terminal window.
    static func interactive(
        partition: String,
        gpus: Int,
        cpus: Int,
        memoryPerCpu: String,
        qos: String,
        credentials: Credentials
    ) {
        let cmd =
            "srun --qos=\(qos) --partition=\(partition) " +
            "--gres=gpu:\(gpus) --cpus-per-task=\(cpus) " +
            "--mem-per-cpu=\(memoryPerCpu) --pty bash -l"
        openSSH(
            host: credentials.host,
            user: credentials.username,
            port: credentials.port,
            remoteCommand: cmd
        )
    }

    #if os(macOS)
    private static func runInTerminal(_ command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var err: NSDictionary?
        appleScript.executeAndReturnError(&err)
    }

    private static func escapeShellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    #endif
}
