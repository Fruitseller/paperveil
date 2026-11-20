import Foundation
import PaperVeilCore
@testable import PaperVeilTransfer
import Testing

/// Test 4: ssh argument construction.
@Suite struct SSHArgumentsTests {
    @Test func argumentsContainSecurityOptionsAndProtocol() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pv-args-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        let knownHosts = KnownHostsStore.defaultFileURL(paths: paths)
        let config = TransferConfiguration(
            host: "example.org",
            port: 2222,
            user: "paperveil",
            identityFilePath: "/Users/test/.ssh/id_ed25519"
        )

        let args = TransferService.sshArguments(
            config: config,
            knownHostsFile: knownHosts,
            name: "PV-1234ABCD-r1.pdf",
            sha256: String(repeating: "a", count: 64),
            byteCount: 5
        )

        func optionValue(after option: String) -> String? {
            guard let i = args.firstIndex(of: option) else { return nil }
            return args[i + 1]
        }

        #expect(optionValue(after: "-o") == "StrictHostKeyChecking=yes")
        // Every security option is present in -o pairs.
        for option in [
            "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=\"\(knownHosts.path)\"",
            "GlobalKnownHostsFile=/dev/null",
            "BatchMode=yes",
            "IdentitiesOnly=yes",
        ] {
            #expect(args.contains("-o") && args.contains(option), "Fehlende ssh-Option: \(option)")
        }
        #expect(args.contains("UserKnownHostsFile=\"\(knownHosts.path)\""), "App-known_hosts muss verwendet werden")
        #expect(optionValue(after: "-F") == "/dev/null", "~/.ssh/config darf die Hostschlüsselprüfung nicht beeinflussen")
        #expect(optionValue(after: "-p") == "2222")
        #expect(optionValue(after: "-i") == "/Users/test/.ssh/id_ed25519")
        #expect(args.contains("paperveil@example.org"))

        guard let separator = args.lastIndex(of: "--") else {
            Issue.record("put-Kommando muss nach -- stehen")
            return
        }
        #expect(args[separator...] == ["--", "put", "PV-1234ABCD-r1.pdf", String(repeating: "a", count: 64), "5"])
    }

    @Test func identityArgumentOmittedWithoutIdentityFile() {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("pv-args-2"))
        let config = TransferConfiguration(host: "example.org", port: 22, user: "paperveil", identityFilePath: nil)
        let args = TransferService.sshArguments(
            config: config,
            knownHostsFile: KnownHostsStore.defaultFileURL(paths: paths),
            name: "PV-1234ABCD-r1.pdf",
            sha256: String(repeating: "b", count: 64),
            byteCount: 0
        )
        #expect(!args.contains("-i"))
        #expect(optionCount(args, "-o") == 5)  // keine -o Duplikate
    }

    @Test func knownHostsPathWithSpacesStaysOneFile() {
        let file = URL(fileURLWithPath: "/Users/x/Library/Application Support/PaperVeil/known_hosts")
        let config = TransferConfiguration(host: "example.org", user: "u", identityFilePath: " /Users/x/.ssh/k.pub")
        let args = TransferService.sshArguments(config: config, knownHostsFile: file, name: "PV-1234ABCD-r1.pdf",
                                                sha256: String(repeating: "c", count: 64), byteCount: 1)
        #expect(args.contains("UserKnownHostsFile=\"\(file.path)\""))
        #expect(args[args.firstIndex(of: "-i")! + 1] == "/Users/x/.ssh/k")
    }

    private func optionCount(_ args: [String], _ option: String) -> Int {
        args.indices.filter { args[$0] == option && $0 + 1 < args.count }.count
    }
}
