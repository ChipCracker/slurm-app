import Foundation

struct SSHKeyFile: Identifiable, Hashable {
    let name: String
    let url: URL
    let preview: String

    var id: String { url.path }
}

/// Reads SSH private keys from the user's `~/.ssh` directory.
/// On iOS the sandbox blocks home-directory access — callers should
/// fall back to a `.fileImporter` (handled in `ConnectionSetupView`).
enum SSHKeyLoader {

    static let candidates = ["id_ed25519", "id_rsa", "id_ecdsa"]

    /// Returns SSH keys found under `~/.ssh/`. Public keys, known_hosts and
    /// config are excluded; only files whose contents start with a PEM header.
    static func discoverDefaultKeys() -> [SSHKeyFile] {
        #if os(macOS)
        let homeSSH = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: homeSSH,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var keys: [SSHKeyFile] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasSuffix(".pub") || name == "known_hosts" || name == "config" || name == "authorized_keys" {
                continue
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-----BEGIN") {
                let preview = String(trimmed.prefix(80))
                keys.append(SSHKeyFile(name: name, url: url, preview: preview))
            }
        }
        return keys.sorted { a, b in
            let ai = candidates.firstIndex(of: a.name) ?? Int.max
            let bi = candidates.firstIndex(of: b.name) ?? Int.max
            if ai != bi { return ai < bi }
            return a.name < b.name
        }
        #else
        // iOS: kein Zugriff auf ~/.ssh (Sandbox). Schlüssel kommen per
        // PEM-Paste in der ConnectionSetupView.
        return []
        #endif
    }

    /// Read a key file as text. Throws on failure.
    static func read(_ file: SSHKeyFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    static var isHomeAccessible: Bool {
        #if os(macOS)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return FileManager.default.fileExists(atPath: url.path)
        #else
        return false
        #endif
    }
}
