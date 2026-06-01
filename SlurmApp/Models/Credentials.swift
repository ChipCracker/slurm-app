import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }
    var label: String {
        switch self {
        case .password:   return "Passwort"
        case .privateKey: return "Privater Schlüssel"
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
