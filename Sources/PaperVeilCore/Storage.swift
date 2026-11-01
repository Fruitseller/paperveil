import Foundation

/// Local storage layout. Default root: ~/Library/Application Support/PaperVeil
///   jobs.json           – queue, findings, approval and transfer state
///   work/<DocumentID>/  – exports (neutral names) per document
///   blocklist.json      – personal blocklist (private, never uploaded)
///   settings.json       – non-secret settings (secrets live in the Keychain)
public struct AppPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func `default`() -> AppPaths {
        // Test/acceptance override, e.g. PAPERVEIL_DATA_DIR=/tmp/pv-acceptance
        if let custom = ProcessInfo.processInfo.environment["PAPERVEIL_DATA_DIR"], !custom.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appendingPathComponent("PaperVeil", isDirectory: true))
    }
    public var jobsFile: URL { root.appendingPathComponent("jobs.json") }
    public var blocklistFile: URL { root.appendingPathComponent("blocklist.json") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var workRoot: URL { root.appendingPathComponent("work", isDirectory: true) }
    public func workDir(for id: DocumentID) -> URL { workRoot.appendingPathComponent(id.rawValue, isDirectory: true) }
    /// Neutral export name: contains only the document ID and revision.
    public func exportURL(for id: DocumentID, revision: Int) -> URL {
        workDir(for: id).appendingPathComponent(Self.exportFileName(id: id, revision: revision))
    }
    public static func exportFileName(id: DocumentID, revision: Int) -> String { "\(id.rawValue)-r\(revision).pdf" }
}

public struct JobRepository: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    public func load() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: paths.jobsFile.path) else { return [] }
        return try JSONDecoder().decode([Job].self, from: Data(contentsOf: paths.jobsFile))
    }

    /// Loads and applies restart recovery (nothing interrupted is shown as done).
    public func loadRecovering() throws -> [Job] {
        try load().map { var j = $0; j.recoverAfterRestart(); return j }
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(jobs).write(to: paths.jobsFile, options: [.atomic, .completeFileProtection])
    }

    /// Deletes PaperVeil's own working data for one document. Never touches the original.
    public func deleteWorkData(for id: DocumentID) throws {
        let dir = paths.workDir(for: id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// Deletes everything under the app root (jobs, exports, blocklist, settings). Originals live elsewhere.
    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: paths.root.path) { try FileManager.default.removeItem(at: paths.root) }
    }
}
