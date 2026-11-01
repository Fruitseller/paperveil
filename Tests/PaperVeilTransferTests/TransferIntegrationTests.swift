import Foundation
import PaperVeilCore
@testable import PaperVeilTransfer
import Testing

/// Test 3: full protocol against the real `receiver/paperveil-receive` script,
/// run locally (LocalReceiverRunner simulates sshd).
@Suite struct TransferIntegrationTests {
    private let config = TransferConfiguration(host: "example.org", port: 22, user: "paperveil")
    private let id = DocumentID(rawValue: "PV-1234ABCD")

    private func expectRemoteRejected(_ error: Error, code: String) -> String? {
        guard case let .remoteRejected(actualCode, message) = error as? TransferError else {
            Issue.record("Falscher Fehler (erwartet remoteRejected/\(code)): \(error)")
            return nil
        }
        #expect(actualCode == code, "Erwarteter Code \(code), erhalten \(actualCode ?? "nil")")
        return message
    }

    @Test func successfulTransferAndIdempotentRetry() async throws {
        let ws = try TransferWorkspace()
        let content = Data("%PDF-1.7 bereinigter test-export\n".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let runner = LocalReceiverRunner(script: TestRepo.receiverScript, inbox: ws.inbox)
        let service = TransferService(paths: ws.paths, runner: runner)

        let first = try await service.transfer(job: job, exportURL: exportURL, config: config)
        #expect(first.remoteName == "PV-1234ABCD-r1.pdf")
        #expect(first.remoteSHA256 == SHA256Hex.of(data: content))

        let final = ws.inbox.appendingPathComponent("PV-1234ABCD-r1.pdf")
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(try Data(contentsOf: final) == content)
        try expectIncomingEmpty(ws.inbox)

        // Retry: same content, same name → idempotent success, no duplicate.
        let second = try await service.transfer(job: job, exportURL: exportURL, config: config)
        #expect(second == first)
        #expect(try Data(contentsOf: final) == content)
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: ws.inbox.path).filter { $0.hasSuffix(".pdf") }
        #expect(pdfs.count == 1)
        try expectIncomingEmpty(ws.inbox)
    }

    @Test func checksumMismatchLeavesNoFinalFile() async throws {
        let ws = try TransferWorkspace()
        let content = Data("%PDF-1.7 inhalt".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let runner = LocalReceiverRunner(script: TestRepo.receiverScript, inbox: ws.inbox, tamperSHA: true)
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: remoteRejected CHECKSUM")
        } catch {
            _ = expectRemoteRejected(error, code: "CHECKSUM")
        }
        #expect(!FileManager.default.fileExists(atPath: ws.inbox.appendingPathComponent("PV-1234ABCD-r1.pdf").path))
        try expectIncomingEmpty(ws.inbox)
    }

    @Test func interruptedUploadIsNoSuccess() async throws {
        let ws = try TransferWorkspace()
        let content = Data("%PDF-1.7 vollstaendiger inhalt mit etwas laenge".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let runner = LocalReceiverRunner(script: TestRepo.receiverScript, inbox: ws.inbox, dropBytes: 7)
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: remoteRejected SIZE")
        } catch {
            _ = expectRemoteRejected(error, code: "SIZE")
        }
        #expect(!FileManager.default.fileExists(atPath: ws.inbox.appendingPathComponent("PV-1234ABCD-r1.pdf").path))
        try expectIncomingEmpty(ws.inbox)
    }

    @Test("Nicht beschreibbarer Posteingang wird abgelehnt", .enabled(if: getuid() != 0))
    func nonWritableInboxFails() async throws {
        let ws = try TransferWorkspace()
        let content = Data("%PDF-1.7 inhalt".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let runner = LocalReceiverRunner(script: TestRepo.receiverScript, inbox: ws.inbox)
        let service = TransferService(paths: ws.paths, runner: runner)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ws.inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ws.inbox.path) }

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: remoteRejected TMP")
        } catch {
            _ = expectRemoteRejected(error, code: "TMP")
        }
        #expect(!FileManager.default.fileExists(atPath: ws.inbox.appendingPathComponent("PV-1234ABCD-r1.pdf").path))
    }

    @Test func differentContentForExistingNameIsRejected() async throws {
        let ws = try TransferWorkspace()
        let firstContent = Data("%PDF-1.7 erste fassung".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: firstContent)
        let job = try ws.makeApprovedJob(id: id, content: firstContent)
        let runner = LocalReceiverRunner(script: TestRepo.receiverScript, inbox: ws.inbox)
        let service = TransferService(paths: ws.paths, runner: runner)

        _ = try await service.transfer(job: job, exportURL: exportURL, config: config)

        // A second, different export claims the same remote name.
        let secondContent = Data("%PDF-1.7 ganz andere fassung".utf8)
        try secondContent.write(to: exportURL)
        var tamperedJob = try ws.makeApprovedJob(id: id, content: firstContent)
        tamperedJob.export?.sha256 = SHA256Hex.of(data: secondContent)
        tamperedJob.approval?.exportSHA256 = SHA256Hex.of(data: secondContent)

        do {
            _ = try await service.transfer(job: tamperedJob, exportURL: exportURL, config: config)
            Issue.record("Erwartet: remoteRejected EXISTS")
        } catch {
            _ = expectRemoteRejected(error, code: "EXISTS")
        }
        // The first file was not overwritten.
        let final = ws.inbox.appendingPathComponent("PV-1234ABCD-r1.pdf")
        #expect(try Data(contentsOf: final) == firstContent)
    }

    private func expectIncomingEmpty(_ inbox: URL) throws {
        let incoming = inbox.appendingPathComponent(".incoming")
        let entries = try FileManager.default.contentsOfDirectory(atPath: incoming.path)
        #expect(entries.isEmpty, "Temporäre Dateien im Eingang übrig: \(entries)")
    }
}
