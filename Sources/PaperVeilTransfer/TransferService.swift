import Foundation
import PaperVeilCore

/// Result of a verified transfer: the receiver confirmed name and checksum.
public struct TransferResult: Equatable, Sendable {
    public let remoteName: String
    public let remoteSHA256: String

    public init(remoteName: String, remoteSHA256: String) {
        self.remoteName = remoteName
        self.remoteSHA256 = remoteSHA256
    }
}

public enum TransferError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The recomputed export hash differs from the approved one: the file was
    /// changed or tampered with after the user's approval.
    case exportTampered(localSHA256: String, expectedSHA256: String)
    /// The export URL is not the app's current export file (originals are refused).
    case invalidExport(String)
    /// The server's host key is unknown or has changed; the connection is refused.
    case hostKeyRejected(String)
    /// The receiver answered `ERR <code> <message>` or failed without a protocol answer.
    case remoteRejected(code: String?, message: String)
    /// The receiver's answer does not match the protocol.
    case protocolError(String)
    /// The ssh process could not be started.
    case launchFailed(String)
    /// The transfer was cancelled; the receiver did not confirm success.
    case cancelled

    public var description: String {
        switch self {
        case let .exportTampered(local, expected):
            "Export entspricht nicht der freigegebenen Prüfsumme (lokal \(local.prefix(12))…, freigegeben \(expected.prefix(12))…)."
        case let .invalidExport(reason):
            "Exportdatei ist nicht die freigegebene Ausgabe: \(reason)"
        case .hostKeyRejected:
            "Serveridentität nicht bestätigt: unbekannter oder geänderter Hostschlüssel."
        case let .remoteRejected(code, message):
            code.map { "Empfang verweigert (\($0)): \(message)" } ?? "Übertragung fehlgeschlagen: \(message)"
        case let .protocolError(detail):
            "Unerwartete Antwort des Empfängers: \(detail)"
        case let .launchFailed(reason):
            "SSH konnte nicht gestartet werden: \(reason)"
        case .cancelled:
            "Übertragung abgebrochen; Empfang wurde nicht bestätigt."
        }
    }
}

/// Transfers approved, sanitized exports to a `paperveil-receive` forced command
/// via the system OpenSSH client (`/usr/bin/ssh`).
///
/// Guarantees (D02–D04 of `docs/ZIELZUSTAND.md`):
/// - only explicitly approved export revisions are sent, otherwise `JobError.notApproved`;
/// - only the app's own export file inside the work directory is accepted as input —
///   originals are refused structurally, not by convention;
/// - the local SHA-256 is recomputed right before the upload and must equal the
///   approved hash and the current export's hash;
/// - success only when the receiver confirms `OK <name> <sha256>` with the local hash
///   after its own server-side verification;
/// - unknown or changed host keys fail the connection (`StrictHostKeyChecking=yes`
///   with an app-managed `known_hosts` file).
public final class TransferService: Sendable {
    public static let sshExecutable = "/usr/bin/ssh"

    /// Neutral export names accepted on the wire, mirroring the receiver.
    public static func isValidExportName(_ name: String) -> Bool {
        name.wholeMatch(of: /^PV-[A-F0-9]{8}-r[0-9]{1,6}\.pdf$/) != nil
    }

    public let paths: AppPaths
    public let runner: CommandRunner

    public init(paths: AppPaths, runner: CommandRunner = ProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    /// The exact ssh argument list used for a transfer. `StrictHostKeyChecking=yes`
    /// plus an app-managed `known_hosts` file mean an unknown or changed host key
    /// fails instead of being accepted; `BatchMode=yes` prevents interactive
    /// prompts (and thus hangs); `IdentitiesOnly=yes` restricts to the configured key.
    public static func sshArguments(
        config: TransferConfiguration,
        knownHostsFile: URL,
        name: String,
        sha256: String,
        byteCount: Int
    ) -> [String] {
        var arguments: [String] = []
        for option in [
            "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=\(knownHostsFile.path)",
            "GlobalKnownHostsFile=/dev/null",
            "BatchMode=yes",
            "IdentitiesOnly=yes",
        ] {
            arguments += ["-o", option]
        }
        arguments += ["-p", String(config.port)]
        if let identity = config.identityFilePath, !identity.isEmpty {
            arguments += ["-i", identity]
        }
        arguments += [config.destination, "--", "put", name, sha256, String(byteCount)]
        return arguments
    }

    /// Runs the `put` protocol against the configured server. Throws
    /// `JobError.notApproved` for anything not explicitly approved.
    public func transfer(job: Job, exportURL: URL, config: TransferConfiguration) async throws -> TransferResult {
        guard job.isApprovedForTransfer else { throw JobError.notApproved }
        guard let approval = job.approval else { throw JobError.notApproved }

        let expectedName = AppPaths.exportFileName(id: job.id, revision: job.revision)
        try Self.validateExport(url: exportURL, expectedName: expectedName, in: paths.workDir(for: job.id))

        // Recompute right before upload: the approved hash must match the actual bytes.
        let localSHA256 = try SHA256Hex.of(fileAt: exportURL)
        guard localSHA256 == approval.exportSHA256, localSHA256 == job.currentExport?.sha256 else {
            throw TransferError.exportTampered(localSHA256: localSHA256, expectedSHA256: approval.exportSHA256)
        }
        let byteCount = try Self.byteCount(of: exportURL)

        let knownHostsFile = KnownHostsStore.defaultFileURL(paths: paths)
        let arguments = Self.sshArguments(
            config: config,
            knownHostsFile: knownHostsFile,
            name: expectedName,
            sha256: localSHA256,
            byteCount: byteCount
        )
        let request = CommandRequest(
            executable: Self.sshExecutable,
            arguments: arguments,
            standardInputFile: exportURL
        )

        let result: CommandResult
        do {
            result = try await runner.run(request)
        } catch is CancellationError {
            throw TransferError.cancelled
        } catch {
            throw TransferError.launchFailed(error.localizedDescription)
        }
        return try Self.interpret(result: result, expectedName: expectedName, localSHA256: localSHA256)
    }

    /// The `TransferState` to record after a verified transfer.
    public static func verifiedTransferState(job: Job, result: TransferResult, date: Date = Date()) -> TransferState {
        .verified(revision: job.revision, remotePath: result.remoteName, sha256: result.remoteSHA256, date: date)
    }

    // MARK: - validation

    private static func validateExport(url: URL, expectedName: String, in workDir: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent().path == workDir.path else {
            throw TransferError.invalidExport("Die Datei liegt nicht im Arbeitsverzeichnis: \(standardized.path)")
        }
        guard standardized.lastPathComponent == expectedName else {
            throw TransferError.invalidExport("Dateiname entspricht nicht dem neutralen Exportnamen: \(expectedName)")
        }
        guard Self.isValidExportName(expectedName) else {
            throw TransferError.invalidExport("Ungültiger neutraler Exportname: \(expectedName)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw TransferError.invalidExport("Exportdatei fehlt: \(standardized.path)")
        }
    }

    private static func byteCount(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw TransferError.invalidExport("Dateigröße konnte nicht ermittelt werden")
        }
        return size.intValue
    }

    // MARK: - protocol interpretation

    private static func interpret(result: CommandResult, expectedName: String, localSHA256: String) throws -> TransferResult {
        let output = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? output

        if result.terminationStatus == 0 {
            let fields = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count == 3, fields[0] == "OK" else {
                throw TransferError.protocolError(output)
            }
            guard fields[1] == expectedName else {
                throw TransferError.protocolError("Bestätigter Name entspricht nicht \(expectedName): \(fields[1])")
            }
            guard fields[2].lowercased() == localSHA256 else {
                throw TransferError.remoteRejected(code: "CHECKSUM", message: "Bestätigte Prüfsumme weicht ab")
            }
            return TransferResult(remoteName: fields[1], remoteSHA256: fields[2].lowercased())
        }

        let combined = result.combinedText
        if combined.contains("Host key verification failed") || combined.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            throw TransferError.hostKeyRejected(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if firstLine.hasPrefix("ERR ") {
            let rest = firstLine.dropFirst("ERR ".count)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            throw TransferError.remoteRejected(
                code: parts.first,
                message: parts.count > 1 ? parts[1] : ""
            )
        }
        throw TransferError.remoteRejected(code: nil, message: combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
