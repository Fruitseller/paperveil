import Foundation
import PaperVeilCore
import PaperVeilDetection
import PaperVeilPipeline
import Testing

/// Real LM Studio run (opt-in, never in CI): F10c contains manipulative instructions plus
/// identifiers. The LLM's contribution must stay visible as provenance even when rules
/// found the same spots, and the injected instruction must not suppress findings.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PAPERVEIL_LMSTUDIO_TEST"] == "1"))
struct RealLLMProvenanceTests {
    @Test func llmProvenanceIsVisibleOnF10c() async throws {
        let model = ProcessInfo.processInfo.environment["PAPERVEIL_LMSTUDIO_MODEL"] ?? "qwen3.8-27b"
        let url = Repo.fixtures.appendingPathComponent("F10c-manipulativ.pdf")
        let llm = LLMConfiguration(endpoint: try LMStudioEndpoint(string: "http://127.0.0.1:1234"), model: model,
                                   timeout: .seconds(600))
        let a = try await DocumentPipeline().analyze(url: url, documentID: .generate(), blocklist: nil, llm: llm)
        for f in a.findings { print("FINDING", f.text, f.origin.rawValue, f.note ?? "-") }
        print("WARNINGS", a.warnings.map(\.kind.rawValue))
        #expect(a.findings.contains { $0.origin == .llm || ($0.note ?? "").contains("LLM") })
        #expect(a.findings.contains { $0.text.contains("Mustermann") })
    }
}
