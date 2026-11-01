import Foundation

/// Non-secret transfer settings, stored by the app (e.g. in `settings.json`).
/// Secrets never belong here: private key passphrases go into the Keychain,
/// private keys stay in the user's `~/.ssh` (D03, D07).
///
/// No default host/user is shipped: the destination is private configuration
/// and must be entered explicitly (E02 – no private content in the repository).
public struct TransferConfiguration: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// Optional path to a private identity file (`ssh -i`). Not a secret itself.
    public var identityFilePath: String?

    public init(host: String, port: Int = 22, user: String, identityFilePath: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFilePath = identityFilePath
    }

    public var destination: String { "\(user)@\(host)" }
}
