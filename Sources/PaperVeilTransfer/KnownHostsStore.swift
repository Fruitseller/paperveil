import Foundation
import PaperVeilCore

/// A server host key: the exact `known_hosts` line plus the SHA256 fingerprint
/// the user must confirm out-of-band before pinning (D03).
public struct HostKey: Codable, Hashable, Sendable {
    public let line: String
    public let fingerprint: String
    public let keyType: String

    public init(line: String, fingerprint: String, keyType: String) {
        self.line = line
        self.fingerprint = fingerprint
        self.keyType = keyType
    }
}

public enum KnownHostsError: Error, Equatable, Sendable {
    /// ssh-keyscan failed or returned no key.
    case scanFailed(String)
    /// The fingerprint could not be computed.
    case fingerprintFailed(String)
    /// The confirmed fingerprint does not match the scanned key; nothing is pinned.
    case fingerprintMismatch(expected: String, confirmed: String)
    case io(String)

    public static func == (lhs: KnownHostsError, rhs: KnownHostsError) -> Bool {
        switch (lhs, rhs) {
        case let (.scanFailed(a), .scanFailed(b)),
            let (.fingerprintFailed(a), .fingerprintFailed(b)),
            let (.io(a), .io(b)):
            a == b
        case let (.fingerprintMismatch(a1, b1), .fingerprintMismatch(a2, b2)):
            a1 == a2 && b1 == b2
        default: false
        }
    }
}

/// App-managed `known_hosts` file (`<AppPaths.root>/known_hosts`). Host keys are
/// only written after the user explicitly confirmed the fingerprint; ssh is
/// always run with `StrictHostKeyChecking=yes` against exactly this file, so an
/// unknown or changed host key fails the connection instead of being accepted
/// silently.
public struct KnownHostsStore: Sendable {
    public let fileURL: URL
    private let runner: CommandRunner

    public init(fileURL: URL, runner: CommandRunner = ProcessRunner()) {
        self.fileURL = fileURL
        self.runner = runner
    }

    public static func defaultFileURL(paths: AppPaths) -> URL {
        paths.root.appendingPathComponent("known_hosts")
    }

    // MARK: - scanning

    /// Scans the host's ed25519 key with `/usr/bin/ssh-keyscan` and computes its
    /// SHA256 fingerprint with `/usr/bin/ssh-keygen -lf`. Nothing is pinned here.
    public func fetchHostKey(host: String, port: Int) async throws -> HostKey {
        var arguments = ["-T", "10", "-t", "ed25519"]
        if port != 22 { arguments += ["-p", String(port)] }
        arguments.append(host)
        let result = try await runner.run(CommandRequest(executable: "/usr/bin/ssh-keyscan", arguments: arguments))
        let lines = result.standardOutputText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard result.terminationStatus == 0, let line = lines.first else {
            throw KnownHostsError.scanFailed(result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try await fingerprint(of: line)
    }

    /// Computes the SHA256 fingerprint of a `known_hosts` line.
    private func fingerprint(of line: String) async throws -> HostKey {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperveil-keyscan-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(line.utf8).write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }
            let result = try await runner.run(CommandRequest(executable: "/usr/bin/ssh-keygen", arguments: ["-lf", tempFile.path]))
            let fields = result.standardOutputText.split(separator: " ").map(String.init)
            // Expected shape: "<bits> SHA256:<fingerprint> <comment> (ED25519)"
            guard result.terminationStatus == 0, fields.count >= 2, fields[1].hasPrefix("SHA256:") else {
                throw KnownHostsError.fingerprintFailed(result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let keyType = fields.last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()")) ?? ""
            return HostKey(line: line, fingerprint: fields[1], keyType: keyType)
        } catch let error as KnownHostsError {
            throw error
        } catch {
            throw KnownHostsError.fingerprintFailed(error.localizedDescription)
        }
    }

    // MARK: - pinning

    /// Pins a scanned host key, but only for the fingerprint the user explicitly
    /// confirmed. A mismatch pins nothing.
    public func pin(_ key: HostKey, confirmedFingerprint: String) throws {
        guard confirmedFingerprint == key.fingerprint else {
            throw KnownHostsError.fingerprintMismatch(expected: key.fingerprint, confirmed: confirmedFingerprint)
        }
        var lines = (try? pinnedLines()) ?? []
        guard !lines.contains(key.line) else { return }
        lines.append(key.line)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: fileURL, options: [.atomic])
    }

    /// The pinned `known_hosts` lines (empty when nothing is pinned yet).
    public func pinnedLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    public func contains(_ key: HostKey) throws -> Bool { try pinnedLines().contains(key.line) }

    /// Removes all pinned keys (part of D07 – stored configuration is deletable).
    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
