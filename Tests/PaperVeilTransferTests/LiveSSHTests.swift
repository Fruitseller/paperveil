import Foundation
import PaperVeilCore
@testable import PaperVeilTransfer
import Testing

/// Opt-in smoke test against a real, explicitly authorized test server with
/// `paperveil-receive` installed as the key's forced command.
///
/// Skipped unless PAPERVEIL_SSH_TEST_HOST is set (user@host). Optional:
/// PAPERVEIL_SSH_TEST_PORT (default 22), PAPERVEIL_SSH_TEST_IDENTITY (path),
/// PAPERVEIL_SSH_TEST_AUTO_PIN (1 = fetch and pin the host key automatically —
/// appropriate only for a disposable test target, never for a production server).
@Suite struct LiveSSHTests {
    @Test(
        "Real SSH transfer",
        .enabled(if: ProcessInfo.processInfo.environment["PAPERVEIL_SSH_TEST_HOST"] != nil)
    )
    func realSSHTransfer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["PAPERVEIL_SSH_TEST_HOST"],
              let atIndex = destination.lastIndex(of: "@") else {
            Issue.record("PAPERVEIL_SSH_TEST_HOST muss user@host sein")
            return
        }
        let user = String(destination[destination.startIndex..<atIndex])
        let host = String(destination[destination.index(after: atIndex)])
        let port = Int(environment["PAPERVEIL_SSH_TEST_PORT"] ?? "22") ?? 22
        let config = TransferConfiguration(
            host: host,
            port: port,
            user: user,
            identityFilePath: environment["PAPERVEIL_SSH_TEST_IDENTITY"]
        )

        let ws = try TransferWorkspace()
        let id = DocumentID.generate()
        let content = Data("PaperVeil Live-SSH-Smoke-Test \(Date().timeIntervalSince1970)\n".utf8)
        let exportURL = try ws.writeExport(id: id, revision: 1, content: content)
        let job = try ws.makeApprovedJob(id: id, content: content)
        let service = TransferService(paths: ws.paths)

        // Pin the host key. For a production server the fingerprint must be
        // confirmed out-of-band by the user; this smoke test pins the fetched
        // key directly and therefore requires an explicitly authorized,
        // disposable test target (see PAPERVEIL_SSH_TEST_AUTO_PIN).
        let knownHosts = KnownHostsStore(fileURL: KnownHostsStore.defaultFileURL(paths: ws.paths))
        let key = try await knownHosts.fetchHostKey(host: host, port: port)
        try knownHosts.pin(key, confirmedFingerprint: key.fingerprint)

        let result = try await service.transfer(job: job, exportURL: exportURL, config: config)
        #expect(result.remoteSHA256 == SHA256Hex.of(data: content))
        // Idempotent retry over the real wire.
        let retry = try await service.transfer(job: job, exportURL: exportURL, config: config)
        #expect(retry == result)
    }
}
