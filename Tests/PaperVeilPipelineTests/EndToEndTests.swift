import Foundation
import PaperVeilCore
import PaperVeilDetection
import PaperVeilPipeline
import PaperVeilTransfer
import Testing

/// End-to-end flow on synthetic fixtures with a real local sshd + receiver:
/// import → analyze → review (accept, reject one, add manual) → export → approve →
/// change after approval → re-export/re-approve → verified transfer.
@Suite(.serialized, .enabled(if: LocalSSHServer.available))
struct EndToEndTests {

    /// Copies a fixture under a "personal" file name so we can check that exports never reuse it.
    func importFixture(_ name: String, into dir: URL) throws -> (URL, String) {
        let dst = dir.appendingPathComponent("Befund Erika Mustermann 2025.pdf")
        try FileManager.default.copyItem(at: Repo.fixtures.appendingPathComponent(name), to: dst)
        return (dst, try SHA256Hex.of(fileAt: dst))
    }

    func pinHostKey(_ server: LocalSSHServer, paths: AppPaths) async throws {
        let store = KnownHostsStore(fileURL: KnownHostsStore.defaultFileURL(paths: paths))
        let key = try await store.fetchHostKey(host: "127.0.0.1", port: server.port)
        try store.pin(key, confirmedFingerprint: key.fingerprint)
    }

    @Test func fullReviewApproveTransferFlow() async throws {
        let work = try tempDir()
        let paths = AppPaths(root: work.appendingPathComponent("app"))
        let (original, hash) = try importFixture("F01-arztbrief.pdf", into: work)
        let server = try LocalSSHServer()
        try server.start()
        defer { server.stop() }
        try await pinHostKey(server, paths: paths)
        let transfer = TransferService(paths: paths)

        var job = Job(originalPath: original.path, originalSHA256: hash, llmRequested: false)
        let blocklist = Blocklist(entries: [.init(value: "Erika Mustermann", category: .name)])
        let analysis = try await DocumentPipeline().analyze(url: original, documentID: job.id, expectedSHA256: hash,
                                                            blocklist: blocklist, llm: nil)
        job.pageCount = analysis.pageCount
        job.findings = analysis.findings
        job.warnings = analysis.warnings
        job.stage = .review
        #expect(job.findings.count >= 5)
        #expect(Set(job.findings.map(\.origin)).isSuperset(of: [.blocklist, .rule]))
        #expect(job.displayStatus == .needsReview)

        // Initial (preview) export exists but no approval → upload must fail.
        job.export = try DocumentPipeline().export(job: job, paths: paths, dpi: 150)
        var exportURL = paths.workDir(for: job.id).appendingPathComponent(job.export!.fileName)
        await #expect(throws: JobError.notApproved) {
            try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.inbox.path).filter { !$0.hasPrefix(".") }.isEmpty)

        // Review: accept all, take one back, add a manual area.
        for f in job.findings { try job.setDecision(.accepted, for: f.id) }
        let rejected = job.findings.first { $0.category == .phone } ?? job.findings[0]
        try job.setDecision(.rejected, for: rejected.id)
        try job.addManualFinding(pageIndex: 0, rect: PageRect(x: 40, y: 40, width: 120, height: 30))
        #expect(job.findings.contains { $0.origin == .manual && $0.decision == .accepted })

        job.export = try DocumentPipeline().export(job: job, paths: paths, dpi: 150)
        #expect(job.export?.validated == true, "\(job.export?.validationMessages ?? [])")
        #expect(!job.export!.fileName.contains("Mustermann"))
        #expect(job.export!.fileName == AppPaths.exportFileName(id: job.id, revision: job.revision))
        try job.confirmReview()
        #expect(job.displayStatus == .readyForApproval)
        try job.approve()
        #expect(job.displayStatus == .approved)

        // Change after approval → approval void, upload refused.
        try job.setDecision(.accepted, for: rejected.id)
        #expect(!job.isApprovedForTransfer)
        #expect(job.displayStatus == .needsReview)
        await #expect(throws: JobError.notApproved) {
            try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
        }

        // Re-export + re-approve → verified transfer.
        job.export = try DocumentPipeline().export(job: job, paths: paths, dpi: 150)
        try job.confirmReview()
        try job.approve()
        exportURL = paths.workDir(for: job.id).appendingPathComponent(job.export!.fileName)
        job.transfer = .inProgress(revision: job.revision)
        #expect(job.displayStatus == .transferring)
        let result = try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
        job.transfer = TransferService.verifiedTransferState(job: job, result: result)
        #expect(job.displayStatus == .transferred)
        let received = server.inbox.appendingPathComponent(result.remoteName)
        #expect(try SHA256Hex.of(fileAt: received) == job.export!.sha256)
        #expect(result.remoteSHA256 == job.export!.sha256)

        // Retry is idempotent: no duplicates.
        _ = try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
        let files = try FileManager.default.contentsOfDirectory(atPath: server.inbox.path).filter { !$0.hasPrefix(".") }
        #expect(files == [result.remoteName])

        // Only the export went over the wire; original unchanged throughout.
        #expect(try SHA256Hex.of(fileAt: original) == hash)
    }

    @Test func unknownAndChangedHostKeysAreRejected() async throws {
        let work = try tempDir()
        let paths = AppPaths(root: work.appendingPathComponent("app"))
        let (original, hash) = try importFixture("F09-ohne-identifikatoren.pdf", into: work)
        let server = try LocalSSHServer()
        try server.start()
        defer { server.stop() }

        var job = Job(originalPath: original.path, originalSHA256: hash, llmRequested: false)
        job.stage = .review
        job.export = try DocumentPipeline().export(job: job, paths: paths, dpi: 100)
        try job.confirmReview(); try job.approve()
        let exportURL = paths.workDir(for: job.id).appendingPathComponent(job.export!.fileName)
        let transfer = TransferService(paths: paths)

        // Unknown host key (nothing pinned) → rejected.
        await #expect(throws: TransferError.self) {
            try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
        }
        do { _ = try await transfer.transfer(job: job, exportURL: exportURL, config: server.config) } catch let e as TransferError {
            if case .hostKeyRejected = e {} else { Issue.record("expected hostKeyRejected, got \(e)") }
        }

        // Pin, succeed; then the server identity changes → rejected, nothing new written.
        try await pinHostKey(server, paths: paths)
        _ = try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
        try server.start(hostKeyName: "other-hostkey")
        do {
            _ = try await transfer.transfer(job: job, exportURL: exportURL, config: server.config)
            Issue.record("changed host key accepted")
        } catch let e as TransferError {
            if case .hostKeyRejected = e {} else { Issue.record("expected hostKeyRejected, got \(e)") }
        }
    }

    @Test func receiverBoundariesOverRealSSH() async throws {
        let work = try tempDir()
        let paths = AppPaths(root: work.appendingPathComponent("app"))
        let server = try LocalSSHServer()
        try server.start()
        defer { server.stop() }
        try await pinHostKey(server, paths: paths)
        let kh = KnownHostsStore.defaultFileURL(paths: paths)
        let payload = work.appendingPathComponent("p.pdf")
        try Data("%PDF-1.7 synthetic".utf8).write(to: payload)
        let sha = try SHA256Hex.of(fileAt: payload)
        let size = "\(try Data(contentsOf: payload).count)"
        let outside = work.appendingPathComponent("evil.txt")

        // Arbitrary commands, path traversal and sftp are all forced through the receiver and fail.
        let attempts: [[String]] = [
            ["sh", "-c", "echo x > \(outside.path)"],
            ["put", "../evil.pdf", sha, size],
            ["put", "/tmp/PV-ABCDEF12-r1.pdf", sha, size],
            ["put", "PV-ABCDEF12-r1.pdf;touch \(outside.path)", sha, size],
        ]
        for a in attempts {
            let (status, out) = try server.ssh(knownHosts: kh, a, stdin: payload)
            #expect(status != 0, "accepted: \(a)")
            #expect(out.contains("ERR"), "\(out)")
        }
        let (sftpStatus, _) = try sh("/usr/bin/sftp", ["-b", "-", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(kh.path)",
                                                      "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", server.clientKey.path,
                                                      "-P", "\(server.port)", "\(NSUserName())@127.0.0.1"])
        #expect(sftpStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: outside.path))

        // Checksum mismatch and interrupted upload → no final file.
        let (s1, o1) = try server.ssh(knownHosts: kh, ["put", "PV-ABCDEF12-r1.pdf", String(repeating: "0", count: 64), size], stdin: payload)
        #expect(s1 != 0 && o1.contains("CHECKSUM"))
        let (s2, o2) = try server.ssh(knownHosts: kh, ["put", "PV-ABCDEF12-r1.pdf", sha, "\(Int(size)! + 100)"], stdin: payload)
        #expect(s2 != 0 && o2.contains("SIZE"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.inbox.path).filter { !$0.hasPrefix(".") }.isEmpty)

        // Missing write permission on the inbox → error, no success.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: server.inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.inbox.path) }
        let (s3, o3) = try server.ssh(knownHosts: kh, ["put", "PV-ABCDEF12-r1.pdf", sha, size], stdin: payload)
        #expect(s3 != 0 && o3.contains("ERR"))
    }
}
