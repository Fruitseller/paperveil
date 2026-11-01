import Foundation

/// Neutral accompanying information for an approved export (D02).
/// Contains only checked, neutral data: document ID, export revision,
/// SHA-256 and byte count. No original file names, no findings, no user data.
public struct Manifest: Codable, Hashable, Sendable {
    public let documentID: String
    public let revision: Int
    public let sha256: String
    public let byteCount: Int

    public init(documentID: String, revision: Int, sha256: String, byteCount: Int) {
        self.documentID = documentID
        self.revision = revision
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
