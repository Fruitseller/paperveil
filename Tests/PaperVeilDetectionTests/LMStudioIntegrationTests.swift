import Foundation
import PaperVeilCore
import Testing
@testable import PaperVeilDetection

/// REAL local LM Studio integration test. Unlike every other test in this
/// module (which uses SIMULATED responses from `SimulatedLMStudioProtocol`),
/// this test talks to the actually running local server at
/// http://127.0.0.1:1234. It only runs when `PAPERVEIL_LMSTUDIO_TEST=1` is
/// set, because CI has no model server (E03/E04); there it must stay skipped.
///
/// The model is chosen from `PAPERVEIL_LMSTUDIO_MODEL` or the first id listed
/// by `GET /v1/models` – model ids always come from the server, never from
/// file names (B03).
struct LMStudioIntegrationTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PAPERVEIL_LMSTUDIO_TEST"] == "1"
    }

    @Test(.enabled(if: Self.isEnabled))
    func realServerDetectsSyntheticPatient() async throws {
        let client = LMStudioClient(endpoint: .localDefault)
        let models = try await client.listModels()
        #expect(!models.isEmpty)
        let model = ProcessInfo.processInfo.environment["PAPERVEIL_LMSTUDIO_MODEL"] ?? models[0]

        // Synthetic page: entirely fictional person (E02: no real data in tests).
        let page = makeSimulatedPage(index: 0, lines: [
            ["Erika", "Mustermann,", "geb.", "12.03.1961,"],
            ["Musterstraße", "5,", "12345", "Musterstadt,", "Kalium", "4,2", "mmol/l"],
        ])

        let detector = LLMDetector(client: client, timeout: .seconds(240))
        let clock = ContinuousClock()
        let start = clock.now
        let result = await detector.detect(
            pages: [page],
            documentID: DocumentID(rawValue: "PV-INTEGRATION"),
            model: model
        )
        let latency = clock.now - start

        // The patient's name must be found with valid, non-empty geometry.
        let nameFindings = result.findings.filter { $0.category == .name && $0.text.contains("Erika") }
        #expect(!nameFindings.isEmpty)
        for finding in result.findings {
            #expect(!finding.rects.isEmpty)
            for rect in finding.rects {
                #expect(rect.width > 0)
                #expect(rect.height > 0)
                #expect(rect.x.isFinite && rect.y.isFinite)
            }
        }

        // Clinical values must never be redacted by this step (B05).
        #expect(!result.findings.contains { $0.text.contains("4,2") })

        // A failed LLM step must not silently count as success.
        #expect(!result.warnings.contains { $0.kind == .llmTimeout || $0.kind == .llmUnavailable })

        print(
            "[REAL LM STUDIO] model=\(model) latency=\(latency) "
                + "findings=\(result.findings.map { "\($0.category)=\($0.text)" }) "
                + "warnings=\(result.warnings.map(\.kind))"
        )
    }
}
