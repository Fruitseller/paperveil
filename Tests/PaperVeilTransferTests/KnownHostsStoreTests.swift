import Foundation
@testable import PaperVeilTransfer
import Testing

@Suite struct KnownHostsStoreTests {
    private static let keyscanOutput = "example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeTestKeyNotARealKey0 paperveil\n"
    private static let keygenOutput = "256 SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 comment (ED25519)\n"

    private func makeStore() throws -> (KnownHostsStore, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("pv-known-hosts-\(UUID().uuidString)")
        return (KnownHostsStore(fileURL: file), file)
    }

    @Test func fetchComputesKeyAndFingerprint() async throws {
        let runner = ScriptedRunner(results: [
            CommandResult(terminationStatus: 0, standardOutput: Data(Self.keyscanOutput.utf8)),
            CommandResult(terminationStatus: 0, standardOutput: Data(Self.keygenOutput.utf8)),
        ])
        let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pv-kh-1"), runner: runner)

        let key = try await store.fetchHostKey(host: "example.org", port: 22)
        #expect(key.line.hasPrefix("example.org ssh-ed25519 AAAA"))
        #expect(key.fingerprint == "SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789")
        #expect(key.keyType == "ED25519")

        // keyscan got the right arguments
        let scan = runner.invocations[0]
        #expect(scan.executable == "/usr/bin/ssh-keyscan")
        #expect(scan.arguments.contains("example.org"))
        #expect(scan.arguments.contains("-t") && scan.arguments.contains("ed25519"))
    }

    @Test func scanFailureThrows() async throws {
        let runner = ScriptedRunner(results: [
            CommandResult(terminationStatus: 1, standardError: Data("connect: timeout".utf8)),
        ])
        let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pv-kh-2"), runner: runner)
        do {
            _ = try await store.fetchHostKey(host: "example.org", port: 22)
            Issue.record("Erwartet: scanFailed")
        } catch let error as KnownHostsError {
            guard case .scanFailed = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
        }
    }

    @Test func pinRequiresConfirmedFingerprint() throws {
        let (store, file) = try makeStore()
        let key = HostKey(
            line: "example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeTestKeyNotARealKey0 paperveil",
            fingerprint: "SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            keyType: "ED25519"
        )

        // Wrong confirmed fingerprint: nothing is pinned.
        #expect(throws: KnownHostsError.self) {
            try store.pin(key, confirmedFingerprint: "SHA256:SomethingElseEntirely")
        }
        #expect(try store.pinnedLines().isEmpty)

        // Correct confirmation pins the key line.
        try store.pin(key, confirmedFingerprint: key.fingerprint)
        #expect(try store.contains(key))
        #expect(try String(contentsOf: file, encoding: .utf8) == key.line + "\n")

        // Pinning again does not duplicate.
        try store.pin(key, confirmedFingerprint: key.fingerprint)
        #expect(try store.pinnedLines().count == 1)

        // D07: deletable.
        try store.clear()
        #expect(try store.pinnedLines().isEmpty)
    }
}

@Suite struct ManifestTests {
    @Test func roundTripKeepsNeutralFields() throws {
        let manifest = Manifest(documentID: "PV-1234ABCD", revision: 2, sha256: String(repeating: "a", count: 64), byteCount: 1234)
        let data = try manifest.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"documentID\" : \"PV-1234ABCD\""))
        #expect(text.contains("\"byteCount\" : 1234"))
        // Neutral only: no file paths, no original names, no findings.
        #expect(!text.contains("/Users"))
        #expect(!text.contains("befund"))

        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        #expect(decoded == manifest)
    }
}
