import Foundation
import PaperVeilCore
import PaperVeilDetection
import PaperVeilExport
import PaperVeilExtraction

public struct LLMConfiguration: Sendable {
    public var endpoint: LMStudioEndpoint
    public var model: String?
    public var timeout: Duration
    public init(endpoint: LMStudioEndpoint, model: String?, timeout: Duration) {
        self.endpoint = endpoint; self.model = model; self.timeout = timeout
    }
}

public struct Analysis: Sendable {
    public var pageCount: Int
    public var pages: [PageText]
    public var findings: [Finding]
    public var warnings: [ProcessingWarning]
}

public enum PipelineError: Error, CustomStringConvertible {
    case originalChanged
    public var description: String {
        switch self {
        case .originalChanged: "Das Original hat sich seit dem Import verändert. Bitte neu importieren."
        }
    }
}

/// Analysis and export steps shared by the app, `pv-eval` and the end-to-end tests.
/// Never writes to the original.
public struct DocumentPipeline: Sendable {
    public init() {}

    public func analyze(url: URL, documentID: DocumentID, expectedSHA256: String? = nil,
                        blocklist: Blocklist?, llm: LLMConfiguration?,
                        progress: @Sendable (ProcessingPhase) -> Void = { _ in }) async throws -> Analysis {
        progress(.validatingInput)
        if let expected = expectedSHA256, try SHA256Hex.of(fileAt: url) != expected { throw PipelineError.originalChanged }
        let validated = try InputValidator.validate(url: url)
        let pageCount = validated.pageCount
        try Task.checkCancellation()

        progress(.extractingText)
        let extraction = try await PageExtractor().extract(url: url, documentID: documentID)
        var warnings = extraction.warnings
        try Task.checkCancellation()

        progress(.rules)
        var findings = blocklist?.detect(in: extraction.pages, documentID: documentID) ?? []
        findings += RuleDetector().detect(in: extraction.pages, documentID: documentID)

        if let llm {
            progress(.llm)
            if let model = llm.model, !model.isEmpty {
                let detector = LLMDetector(client: LMStudioClient(endpoint: llm.endpoint), timeout: llm.timeout)
                let r = await detector.detect(pages: extraction.pages, documentID: documentID, model: model)
                findings += r.findings
                warnings += r.warnings
            } else {
                warnings.append(ProcessingWarning(kind: .llmUnavailable,
                    message: "LLM-Prüfung angefordert, aber kein Modell ausgewählt. Die LLM-Prüfung wurde nicht durchgeführt."))
            }
            try Task.checkCancellation()
        }
        if let expected = expectedSHA256, try SHA256Hex.of(fileAt: url) != expected { throw PipelineError.originalChanged }
        findings += Self.propagate(findings, in: extraction.pages, documentID: documentID)
        return Analysis(pageCount: pageCount, pages: extraction.pages, findings: Self.deduplicate(findings), warnings: warnings)
    }

    /// A value found once (e.g. a name after "Patientin:") is also searched everywhere else in
    /// the document, including occurrences without context such as a bare header line.
    /// Matching uses the blocklist's variant logic; the origin of the source finding is kept.
    public static func propagate(_ findings: [Finding], in pages: [PageText], documentID: DocumentID) -> [Finding] {
        var result: [Finding] = []
        for origin in FindingOrigin.allCases where origin != .manual {
            let entries = Set(findings.filter { $0.origin == origin && $0.text.count >= 4 }
                .map { Blocklist.Entry(value: $0.text.replacingOccurrences(of: "\n", with: " "), category: $0.category) })
            guard !entries.isEmpty else { continue }
            result += Blocklist(entries: Array(entries)).detect(in: pages, documentID: documentID).map {
                var f = $0
                f.origin = origin
                f.note = "Weitere Fundstelle eines erkannten Werts"
                return f
            }
        }
        return result
    }

    /// Drops findings whose rects are identical to an earlier one on the same page
    /// (priority: blocklist > rule > llm > manual, by input order).
    public static func deduplicate(_ findings: [Finding]) -> [Finding] {
        var seen = Set<String>()
        return findings.filter { f in
            let key = "\(f.pageIndex)|" + f.rects.map { r in
                String(format: "%.1f,%.1f,%.1f,%.1f", r.x, r.y, r.width, r.height)
            }.joined(separator: ";")
            return seen.insert(key).inserted
        }
    }

    /// Exports the job's current revision into its work dir and validates the result.
    public func export(job: Job, paths: AppPaths, dpi: Double,
                       progress: @Sendable (ProcessingPhase) -> Void = { _ in }) throws -> ExportRecord {
        let original = URL(fileURLWithPath: job.originalPath)
        guard try SHA256Hex.of(fileAt: original) == job.originalSHA256 else { throw PipelineError.originalChanged }
        try FileManager.default.createDirectory(at: paths.workDir(for: job.id), withIntermediateDirectories: true)
        let dest = paths.exportURL(for: job.id, revision: job.revision)
        progress(.exporting)
        let outcome = try RasterExporter.export(original: original, findings: job.findings, to: dest, dpi: dpi)
        progress(.validatingExport)
        let report = ExportValidator.validate(export: dest, original: original, findings: job.findings, dpi: dpi)
        let unchanged = (try? SHA256Hex.of(fileAt: original)) == job.originalSHA256
        var messages = report.messages
        if !unchanged { messages.append("Original-Hash nach dem Export verändert.") }
        return ExportRecord(revision: job.revision, fileName: dest.lastPathComponent, sha256: outcome.sha256,
                            pageCount: outcome.pageCount, validated: report.passed && unchanged, validationMessages: messages)
    }
}
