import Foundation
import PaperVeilCore

struct ProcessOutput: Sendable {
    var pageCount: Int
    var findings: [Finding]
    var warnings: [ProcessingWarning]
    var export: ExportRecord?
}

struct TransferOutcome: Sendable { var remoteName: String; var sha256: String }

/// Glue between the app and the processing modules. Runs off the main actor.
struct Engine: Sendable {
    let paths: AppPaths

    func loadBlocklistData() throws -> Data? {
        FileManager.default.fileExists(atPath: paths.blocklistFile.path) ? try Data(contentsOf: paths.blocklistFile) : nil
    }

    func process(job: Job, settings: AppSettings, blocklist: Data?,
                 progress: @escaping @Sendable (ProcessingPhase) -> Void) async -> Result<ProcessOutput, Error> {
        .failure(CancellationError()) // TODO: wire modules
    }

    func export(job: Job, dpi: Double) async -> Result<ExportRecord, Error> {
        .failure(CancellationError()) // TODO
    }

    func transfer(job: Job) async -> Result<TransferOutcome, Error> {
        .failure(CancellationError()) // TODO
    }

    func deleteSecrets() throws {}
}
