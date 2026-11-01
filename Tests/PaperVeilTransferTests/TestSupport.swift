import Foundation
import PaperVeilCore
@testable import PaperVeilTransfer
import Testing

/// Locates the repository (test bundle paths are not the cwd on all runners).
enum TestRepo {
    static var receiverScript: URL {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testDir.deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("receiver/paperveil-receive")
    }
}

/// Fresh temp root with an `AppPaths` layout plus a local receiver inbox.
struct TransferWorkspace {
    let root: URL
    let paths: AppPaths
    let inbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pv-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
        inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    /// Writes an export file at the canonical path inside the work directory.
    @discardableResult
    func writeExport(id: DocumentID, revision: Int = 1, content: Data) throws -> URL {
        let url = paths.exportURL(for: id, revision: revision)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        return url
    }

    /// A fully approved job for the given export content (stage = review,
    /// finding accepted, review confirmed, export attached, approved).
    func makeApprovedJob(id: DocumentID = DocumentID(rawValue: "PV-1234ABCD"), content: Data) throws -> Job {
        var job = Job(
            id: id,
            originalPath: "/privat/test/unterlagen/befund.pdf",
            originalSHA256: SHA256Hex.of(data: Data("original".utf8)),
            llmRequested: false
        )
        job.stage = .review
        job.findings = [
            Finding(
                documentID: id,
                pageIndex: 0,
                rects: [PageRect(x: 0, y: 0, width: 10, height: 10)],
                text: "Max Mustermann",
                category: .name,
                origin: .rule,
                decision: .accepted
            )
        ]
        try job.confirmReview()
        job.export = ExportRecord(
            revision: 1,
            fileName: AppPaths.exportFileName(id: id, revision: 1),
            sha256: SHA256Hex.of(data: content),
            pageCount: 1,
            validated: true,
            validationMessages: []
        )
        try job.approve()
        return job
    }
}

/// Records every invocation and returns a canned result.
final class MockRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CommandRequest] = []
    private let result: CommandResult

    init(result: CommandResult) {
        self.result = result
    }

    var invocations: [CommandRequest] { lock.withLock { requests } }
    var invocationCount: Int { lock.withLock { requests.count } }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        let result = lock.withLock { () -> CommandResult in
            requests.append(request)
            return result
        }
        return result
    }
}

/// Returns queued results in order; records requests.
final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CommandRequest] = []
    private var results: [CommandResult]

    init(results: [CommandResult]) {
        self.results = results
    }

    var invocations: [CommandRequest] { lock.withLock { requests } }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        return try lock.withLock { () throws -> CommandResult in
            requests.append(request)
            guard !results.isEmpty else {
                throw TransferError.launchFailed("kein weiteres Ergebnis für Test")
            }
            return results.removeFirst()
        }
    }
}

/// Executes `receiver/paperveil-receive` directly in a local inbox, simulating
/// what sshd does: it translates the `ssh … -- put name sha size` invocation
/// into `SSH_ORIGINAL_COMMAND` and streams the file to the script's stdin.
struct LocalReceiverRunner: CommandRunner {
    let script: URL
    let inbox: URL
    /// Sends the checksum of other content → receiver reports ERR CHECKSUM.
    var tamperSHA = false
    /// Sends fewer bytes than declared → simulates an interrupted upload.
    var dropBytes: Int?
    private let process = ProcessRunner()

    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard let separator = request.arguments.lastIndex(of: "--"),
              request.arguments.count == separator + 5,
              request.arguments[separator + 1] == "put" else {
            throw TransferError.protocolError("LocalReceiverRunner: kein put-Kommando in \(request.arguments)")
        }
        let name = request.arguments[separator + 2]
        var sha = request.arguments[separator + 3]
        let size = request.arguments[separator + 4]
        if tamperSHA {
            sha = SHA256Hex.of(data: Data("andere inhalte".utf8))
        }
        guard let input = request.standardInputFile else {
            throw TransferError.protocolError("LocalReceiverRunner: stdin-Datei fehlt")
        }
        var stdinFile = input
        if let drop = dropBytes, drop > 0 {
            let data = try Data(contentsOf: input)
            let truncated = FileManager.default.temporaryDirectory
                .appendingPathComponent("pv-truncated-\(UUID().uuidString)")
            try data.prefix(max(0, data.count - drop)).write(to: truncated)
            stdinFile = truncated
        }
        let localRequest = CommandRequest(
            executable: "/bin/sh",
            arguments: [script.path, inbox.path],
            environment: ["SSH_ORIGINAL_COMMAND": "put \(name) \(sha) \(size)"],
            standardInputFile: stdinFile
        )
        return try await process.run(localRequest)
    }
}
