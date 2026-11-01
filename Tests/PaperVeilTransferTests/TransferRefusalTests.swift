import Foundation
import PaperVeilCore
@testable import PaperVeilTransfer
import Testing

/// Tests 1 and 2: approval and integrity gate before anything is sent.
@Suite struct TransferRefusalTests {
    private let config = TransferConfiguration(host: "example.org", port: 22, user: "paperveil")
    private let id = DocumentID(rawValue: "PV-1234ABCD")

    @Test func unapprovedJobIsRefusedAndRunnerNeverInvoked() async throws {
        let ws = try TransferWorkspace()
        let content = Data("bereinigter export".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        var job = try ws.makeApprovedJob(id: id, content: content)
        job.revokeApproval()

        let runner = MockRunner(result: CommandResult(terminationStatus: 0, standardOutput: Data("OK PV-1234ABCD-r1.pdf abc".utf8)))
        let service = TransferService(paths: ws.paths, runner: runner)

        await #expect(throws: JobError.notApproved) {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func jobWithoutExportIsRefused() async throws {
        let ws = try TransferWorkspace()
        let content = Data("bereinigter export".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        var job = try ws.makeApprovedJob(id: id, content: content)
        job.export = nil
        job.revokeApproval()

        let runner = MockRunner(result: CommandResult(terminationStatus: 0))
        let service = TransferService(paths: ws.paths, runner: runner)

        await #expect(throws: JobError.notApproved) {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func approvedJobWithTamperedExportIsRefused() async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt v1".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)

        // Tamper after approval: same file, different bytes.
        try Data("export inhalt v1 mit heimlicher aenderung".utf8).write(to: exportURL)

        let runner = MockRunner(result: CommandResult(terminationStatus: 0))
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: exportTampered")
        } catch let error as TransferError {
            guard case .exportTampered = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
            #expect(runner.invocations.isEmpty)
        }
    }

    @Test func originalOutsideWorkDirIsRefused() async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt".utf8)
        _ = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)

        // An original outside the work dir, named like a real document.
        let original = ws.root.appendingPathComponent("befund-original.pdf")
        try content.write(to: original)

        let runner = MockRunner(result: CommandResult(terminationStatus: 0))
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: original, config: config)
            Issue.record("Erwartet: invalidExport für Original")
        } catch let error as TransferError {
            guard case .invalidExport = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
            #expect(runner.invocations.isEmpty)
        }
    }

    @Test func wronglyNamedFileInsideWorkDirIsRefused() async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt".utf8)
        let job = try ws.makeApprovedJob(id: id, content: content)
        _ = try ws.writeExport(id: id, revision: 1, content: content)

        let otherName = ws.paths.workDir(for: id).appendingPathComponent("nicht-neutral.pdf")
        try FileManager.default.createDirectory(at: otherName.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: otherName)

        let runner = MockRunner(result: CommandResult(terminationStatus: 0))
        let service = TransferService(paths: ws.paths, runner: runner)
        do {
            _ = try await service.transfer(job: job, exportURL: otherName, config: config)
            Issue.record("Erwartet: invalidExport für falschen Dateinamen")
        } catch let error as TransferError {
            guard case .invalidExport = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
            #expect(runner.invocations.isEmpty)
        }
    }
}
