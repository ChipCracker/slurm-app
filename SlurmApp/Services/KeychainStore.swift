import Foundation
import Security

enum KeychainError: Error {
    case unhandled(OSStatus)
    case encoding
}

final class KeychainStore {
    static let shared = KeychainStore()
    // Per-bundle-id service so the dev build (de.cwitzl.slurmapp.dev) and the
    // stable build keep separate credentials, matching the documented dev/prod
    // isolation. Falls back to the stable id if somehow unavailable.
    private let service = Bundle.main.bundleIdentifier ?? "de.cwitzl.slurmapp"
    /// Older builds stored credentials under the hardcoded Release id for BOTH
    /// flavours. Read once as a fallback so switching to per-bundle isolation
    /// doesn't orphan existing logins.
    private static let legacyService = "de.cwitzl.slurmapp"
    private let account = "kiz0-credentials"
    // Available after first unlock (so auto-connect works post-reboot) but
    // ThisDeviceOnly so the secret never leaves the device via iCloud Keychain
    // or an encrypted backup.
    private let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    func saveCredentials(_ creds: Credentials) throws {
        let data = try JSONEncoder().encode(creds)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  accessible,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandled(updateStatus)
        }
    }

    func loadCredentials() throws -> Credentials? {
        if let creds = try load(from: service) { return creds }
        // One-time migration: adopt credentials saved by an older build under the
        // legacy (shared) service into this build's per-bundle service.
        if service != Self.legacyService, let legacy = try load(from: Self.legacyService) {
            try? saveCredentials(legacy)
            return legacy
        }
        return nil
    }

    private func load(from service: String) throws -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }

        guard let data = item as? Data else { throw KeychainError.encoding }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
