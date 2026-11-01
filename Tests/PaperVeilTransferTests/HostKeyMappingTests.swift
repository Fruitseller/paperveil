import Foundation
import PaperVeilCore
@testable import PaperVeilTransfer
import Testing

/// Test 5: unknown or changed host keys map to `.hostKeyRejected`.
@Suite struct HostKeyMappingTests {
    private let config = TransferConfiguration(host: "example.org", port: 22, user: "paperveil")
    private let id = DocumentID(rawValue: "PV-1234ABCD")

    private func expectHostKeyRejected(runner: MockRunner) async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let service = TransferService(paths: ws.paths, runner: runner)
        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: hostKeyRejected")
        } catch let error as TransferError {
            guard case .hostKeyRejected = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
        }
    }

    @Test func unknownHostKeyIsRejectedExplicitly() async throws {
        let runner = MockRunner(result: CommandResult(
            terminationStatus: 255,
            standardError: Data("ssh: Host key verification failed.\r\n".utf8)
        ))
        try await expectHostKeyRejected(runner: runner)
    }

    @Test func changedHostKeyIsRejectedExplicitly() async throws {
        let banner = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        """
        let runner = MockRunner(result: CommandResult(
            terminationStatus: 255,
            standardError: Data(banner.utf8)
        ))
        try await expectHostKeyRejected(runner: runner)
    }

    @Test func receiverErrorMessageBecomesRemoteRejected() async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let runner = MockRunner(result: CommandResult(
            terminationStatus: 1,
            standardOutput: Data("ERR CHECKSUM checksum mismatch: received x, expected y\n".utf8)
        ))
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: remoteRejected")
        } catch let error as TransferError {
            guard case let .remoteRejected(code, message) = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
            #expect(code == "CHECKSUM")
            #expect(message.contains("checksum mismatch"))
        }
    }

    @Test func nonProtocolSuccessOutputIsRejected() async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let runner = MockRunner(result: CommandResult(
            terminationStatus: 0,
            standardOutput: Data("alles klar, tschuess\n".utf8)
        ))
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: protocolError")
        } catch let error as TransferError {
            guard case .protocolError = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
        }
    }

    @Test func confirmedHashMustMatchServerConfirmation() async throws {
        let ws = try TransferWorkspace()
        let content = Data("export inhalt".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let wrongHash = String(repeating: "c", count: 64)
        let runner = MockRunner(result: CommandResult(
            terminationStatus: 0,
            standardOutput: Data("OK PV-1234ABCD-r1.pdf \(wrongHash)\n".utf8)
        ))
        let service = TransferService(paths: ws.paths, runner: runner)

        do {
            _ = try await service.transfer(job: job, exportURL: exportURL, config: config)
            Issue.record("Erwartet: remoteRejected wegen abweichender Bestätigungs-Prüfsumme")
        } catch let error as TransferError {
            guard case let .remoteRejected(code, _) = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
            #expect(code == "CHECKSUM")
        }
    }
}
