import Foundation
import PaperVeilCore
import PaperVeilDetection
import PaperVeilPipeline

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
    private let pipeline = DocumentPipeline()

    func loadBlocklistData() throws -> Data? {
        FileManager.default.fileExists(atPath: paths.blocklistFile.path) ? try Data(contentsOf: paths.blocklistFile) : nil
    }

    func loadBlocklist() -> Blocklist {
        (try? Blocklist.load(from: paths.blocklistFile)) ?? Blocklist()
    }

    func saveBlocklist(_ b: Blocklist) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try b.save(to: paths.blocklistFile)
    }

    func process(job: Job, settings: AppSettings, blocklist: Data?,
                 progress: @escaping @Sendable (ProcessingPhase) -> Void) async -> Result<ProcessOutput, Error> {
        do {
            let list = blocklist.flatMap { try? JSONDecoder().decode(Blocklist.self, from: $0) }
            var llm: LLMConfiguration?
            if settings.llmEnabled {
                llm = LLMConfiguration(endpoint: try LMStudioEndpoint(string: settings.llmEndpoint), model: settings.llmModel,
                                       timeout: .seconds(settings.llmTimeoutSeconds))
            }
            let analysis = try await pipeline.analyze(url: URL(fileURLWithPath: job.originalPath), documentID: job.id,
                                                      expectedSHA256: job.originalSHA256, blocklist: list, llm: llm,
                                                      progress: progress)
            try Task.checkCancellation()
            // Preview export of all proposed (not rejected) findings incl. earlier manual ones.
            var preview = job
            preview.findings = job.findings.filter { $0.origin == .manual } + analysis.findings
            preview.pageCount = analysis.pageCount
            let export = try? pipeline.export(job: preview, paths: paths, dpi: settings.exportDPI, progress: progress)
            return .success(ProcessOutput(pageCount: analysis.pageCount, findings: analysis.findings,
                                          warnings: analysis.warnings, export: export))
        } catch {
            return .failure(error)
        }
    }

    func export(job: Job, dpi: Double) async -> Result<ExportRecord, Error> {
        Result { try pipeline.export(job: job, paths: paths, dpi: dpi) }
    }

    func llmStatus(endpoint: String) async -> (models: [String], error: String?) {
        do {
            let client = LMStudioClient(endpoint: try LMStudioEndpoint(string: endpoint))
            switch await client.status() {
            case .reachable(let models): return (models, nil)
            case .unreachable(let msg): return ([], msg)
            }
        } catch {
            return ([], AppModel.describe(error))
        }
    }

    func transfer(job: Job) async -> Result<TransferOutcome, Error> {
        .failure(CancellationError()) // wired after transfer module lands
    }

    func deleteSecrets() throws {}
}
