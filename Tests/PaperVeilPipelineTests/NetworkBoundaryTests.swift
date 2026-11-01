import Foundation
import Testing
import PaperVeilDetection

/// D01 (Netzwerkgrenze) – statische Abnahmeprüfung.
///
/// These tests pin the network boundary of the app **statically** against the
/// sources: networking APIs, external-process APIs and hard-coded URL literals
/// may only live where document content is allowed to travel:
///
/// - `URLSession`/`URLRequest`/… only in `Sources/PaperVeilDetection/LMStudio*.swift`
///   (loopback-only LM Studio client, validated by `LMStudioEndpoint`);
/// - `Process`/`/usr/bin/ssh*` only in `Sources/PaperVeilTransfer/` (explicit,
///   user-approved SSH export) and in the repo-local tooling targets
///   `Sources/pv-fixtures/`, `Sources/pv-eval/`;
/// - no hard-coded non-loopback `http(s)` URL literals anywhere in `Sources/`
///   (documentation comments are exempt because they are stripped first);
/// - `LMStudioEndpoint` rejects every non-loopback host, so the only networking
///   module cannot be pointed at a cloud endpoint.
///
/// The **dynamic** counterpart of D01 (offline run under `sandbox-exec`, live
/// connection sampling, sandbox-log check) is `scripts/network-check.sh`; the
/// log-hygiene check for D07 is `scripts/log-check.sh`. Both are documented in
/// `docs/acceptance/network-and-logs.md`.
@Suite struct NetworkBoundaryTests {

    // MARK: - Repository location and source scanning

    /// Repo root, derived from this file's location:
    /// `<root>/Tests/PaperVeilPipelineTests/NetworkBoundaryTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PaperVeilPipelineTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    private struct SourceFile: Sendable {
        /// Path relative to the repo root, e.g. `Sources/PaperVeilApp/Engine.swift`.
        let relativePath: String
        /// Source text with Swift comments removed; string literals are kept
        /// (URL literals inside strings are exactly what must be checked).
        let code: String
    }

    /// Every `.swift` file under `Sources/`, comments stripped.
    private static func sourceFiles() throws -> [SourceFile] {
        let sourcesRoot = repoRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let rootPath = repoRoot.path
        var result: [SourceFile] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let relativePath = String(url.path.dropFirst(rootPath.count + 1))
            result.append(SourceFile(relativePath: relativePath, code: stripComments(from: text)))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// Removes `//` line comments, `///` doc comments and `/* … */` block
    /// comments. String literals (including `"""` multiline strings) are kept
    /// intact, because URL literals inside strings are exactly what the
    /// boundary check must inspect. Regex literals are not tracked separately;
    /// no source in this repo contains `//` or `/*` inside a regex literal.
    private static func stripComments(from source: String) -> String {
        var kept: [String] = []
        var inBlockComment = false
        var inMultilineString = false
        for line in source.components(separatedBy: "\n") {
            if inMultilineString {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("\"\"\"") {
                    inMultilineString = false
                    kept.append("")
                } else {
                    kept.append(line) // raw multiline-string content
                }
                continue
            }
            var output = ""
            var index = line.startIndex
            var inString = false
            while index < line.endIndex {
                let rest = line[index...]
                if inBlockComment {
                    if rest.hasPrefix("*/") {
                        inBlockComment = false
                        index = line.index(index, offsetBy: 2)
                    } else {
                        index = line.index(after: index)
                    }
                    continue
                }
                if inString {
                    if rest.hasPrefix("\\") {
                        // escaped character (\", \\, \n, …): keep verbatim
                        output += rest.prefix(2)
                        index = line.index(index, offsetBy: 2)
                    } else if rest.hasPrefix("\"") {
                        inString = false
                        output += "\""
                        index = line.index(after: index)
                    } else {
                        output.append(line[index])
                        index = line.index(after: index)
                    }
                    continue
                }
                // code state
                if rest.hasPrefix("\"\"\"") {
                    // opening delimiter; Swift requires a newline after it,
                    // so the content starts on the following line.
                    inMultilineString = true
                    break
                }
                if rest.hasPrefix("//") { break } // line comment: drop rest of line
                if rest.hasPrefix("/*") {
                    inBlockComment = true
                    index = line.index(index, offsetBy: 2)
                    continue
                }
                if rest.hasPrefix("\"") {
                    inString = true
                    output += "\""
                    index = line.index(after: index)
                    continue
                }
                output.append(line[index])
                index = line.index(after: index)
            }
            kept.append(output)
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Location policies

    /// The only permitted networking location: the LM Studio client files.
    private static func isLMStudioClient(_ path: String) -> Bool {
        path.hasPrefix("Sources/PaperVeilDetection/LMStudio")
    }

    /// External-process APIs are permitted in the transfer module and in the
    /// repo-local tooling targets only.
    private static func isProcessPermitted(_ path: String) -> Bool {
        path.hasPrefix("Sources/PaperVeilTransfer/")
            || path.hasPrefix("Sources/pv-fixtures/")
            || path.hasPrefix("Sources/pv-eval/")
    }

    // MARK: - Tests

    /// Guard against a vacuous scan (wrong repo root, empty `Sources/`).
    @Test func sourceScanFindsTheExpectedFiles() throws {
        let files = try Self.sourceFiles()
        #expect(files.count > 30)
        let paths = Set(files.map(\.relativePath))
        #expect(paths.contains("Sources/PaperVeilDetection/LMStudioClient.swift"))
        #expect(paths.contains("Sources/PaperVeilDetection/LMStudioEndpoint.swift"))
        #expect(paths.contains("Sources/PaperVeilTransfer/TransferService.swift"))
        #expect(paths.contains("Sources/PaperVeilApp/AppModel.swift"))
    }

    /// D01: networking APIs (`URLSession`, `URLRequest`, `NWConnection`,
    /// `CFStream`, `Socket`, literal `URL(string: "http…")`) exist only in the
    /// LM Studio client files.
    @Test func networkingAPIsOccurOnlyInLMStudioClient() throws {
        let files = try Self.sourceFiles()
        let patterns = [
            "URLSession", "URLRequest", "NWConnection", "CFStream", "Socket",
            #"URL(string: "http"#,
        ]
        var violations: [String] = []
        var lmStudioNetworkingSeen = false
        for file in files {
            for pattern in patterns where file.code.contains(pattern) {
                if Self.isLMStudioClient(file.relativePath) {
                    lmStudioNetworkingSeen = true
                } else {
                    violations.append("\(file.relativePath) contains \(pattern)")
                }
            }
        }
        // The scan must actually see the client's networking (non-vacuous).
        #expect(lmStudioNetworkingSeen)
        if !violations.isEmpty {
            Issue.record(
                "Networking APIs outside LMStudio*.swift (D01): \(violations.joined(separator: "; "))"
            )
        }
    }

    /// D01/D03: `Process` and `/usr/bin/ssh*` exist only in the transfer module
    /// (explicit, approved SSH export) and in the repo-local tooling targets.
    @Test func processAndSSHOnlyInTransferAndTooling() throws {
        let files = try Self.sourceFiles()
        let processRegex = try NSRegularExpression(pattern: #"\bProcess\b"#)
        let pathLiterals = ["/usr/bin/ssh", "NSTask", "posix_spawn"]
        var violations: [String] = []
        var transferProcessSeen = false
        for file in files {
            let range = NSRange(file.code.startIndex..., in: file.code)
            let usesProcess = !processRegex.matches(in: file.code, range: range).isEmpty
            let hits = pathLiterals.filter { file.code.contains($0) }
            guard usesProcess || !hits.isEmpty else { continue }
            if file.relativePath.hasPrefix("Sources/PaperVeilTransfer/") {
                transferProcessSeen = true
            } else if !Self.isProcessPermitted(file.relativePath) {
                let found = (usesProcess ? ["Process"] : []) + hits
                violations.append("\(file.relativePath) uses \(found.joined(separator: ", "))")
            }
        }
        // The transfer module really spawns /usr/bin/ssh (non-vacuous).
        #expect(transferProcessSeen)
        if !violations.isEmpty {
            Issue.record(
                "Process/ssh outside permitted modules (D01): \(violations.joined(separator: "; "))"
            )
        }
    }

    /// D01: no hard-coded non-loopback `http(s)` URL literals in `Sources/`
    /// outside documentation comments (comments are stripped before matching).
    @Test func noHardCodedNonLoopbackURLs() throws {
        let files = try Self.sourceFiles()
        let urlRegex = try NSRegularExpression(pattern: #"https?://[A-Za-z0-9\.\[\]:_\-]*"#)
        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var violations: [String] = []
        var loopbackLiteralSeen = false
        for file in files {
            let range = NSRange(file.code.startIndex..., in: file.code)
            for match in urlRegex.matches(in: file.code, range: range) {
                guard let literal = file.code.substring(at: match.range) else { continue }
                guard let schemeEnd = literal.range(of: "://") else { continue }
                var host = String(literal[schemeEnd.upperBound...])
                if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
                if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
                if host.isEmpty {
                    // e.g. "http://\(host):…" – host is interpolated and cannot
                    // be verified statically; that pattern is rejected.
                    violations.append("\(file.relativePath): interpolated host in \"\(literal)\"")
                    continue
                }
                if allowedHosts.contains(host) {
                    loopbackLiteralSeen = true
                    continue
                }
                violations.append("\(file.relativePath): non-loopback URL literal \"\(literal)\"")
            }
        }
        // The LM Studio default endpoint is present as a literal (non-vacuous).
        #expect(loopbackLiteralSeen)
        if !violations.isEmpty {
            Issue.record(
                "Hard-coded non-loopback URL literals in Sources/ (D01): \(violations.joined(separator: "; "))"
            )
        }
    }

    // MARK: - D01: LMStudioEndpoint rejects every non-loopback host

    /// The only networking module must be structurally unable to leave the
    /// loopback: https, LAN addresses, and DNS/host-suffix tricks that resolve
    /// elsewhere are all rejected at init. No cloud fallback exists anywhere.
    @Test func endpointRejectsNonLoopbackHosts() {
        let rejected = [
            "https://api.openai.com",       // cloud API, https
            "http://192.168.1.10:1234",     // LAN host
            "http://localhost.evil.com",    // attacker-controlled suffix of "localhost"
            "http://127.0.0.1.nip.io",      // DNS wildcard service
            "http://10.0.0.5:1234",         // private range
            "http://[::2]:1234",            // non-loopback IPv6
            "http://sub.localhost:1234",    // dot-suffixed "localhost"
            "http://0.0.0.0:1234",          // wildcard address
            "http://user:pass@127.0.0.1:1234", // credentials
            "ws://127.0.0.1:1234",          // non-http scheme
        ]
        for candidate in rejected {
            #expect(throws: LMStudioEndpoint.EndpointError.self) {
                try LMStudioEndpoint(string: candidate)
            }
        }
    }

    @Test func endpointAcceptsOnlyLoopback() throws {
        for loopback in ["http://127.0.0.1:1234", "http://localhost:1234", "http://[::1]:1234"] {
            let endpoint = try LMStudioEndpoint(string: loopback)
            #expect(["127.0.0.1", "::1", "localhost"].contains(endpoint.url.host() ?? ""))
        }
        #expect(LMStudioEndpoint.localDefault.url.absoluteString == "http://127.0.0.1:1234")
    }
}

private extension String {
    func substring(at range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
