import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }
    // String-Property lokalisiert nicht automatisch → explizit über den Katalog.
    var label: String {
        switch self {
        case .password:   return String(localized: "Passwort")
        case .privateKey: return String(localized: "Privater Schlüssel")
        }
    }
}

struct Credentials: Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var password: String?
    var privateKey: String?
    var passphrase: String?
    /// Pinned SHA-256 host-key fingerprint (lowercase hex). Set on first
    /// successful connect (trust-on-first-use); every later connect/reconnect
    /// verifies the live key against it and hard-fails on a mismatch (MITM).
    /// nil = not yet pinned. Optional with a default so old Keychain blobs and
    /// existing initializers decode/compile unchanged.
    var hostFingerprint: String? = nil

    static let kiz0Default = Credentials(
        host: "kiz0.in.ohmportal.de",
        port: 22,
        username: "",
        authMethod: .password,
        password: nil,
        privateKey: nil,
        passphrase: nil
    )
}
