import Foundation
import PaperVeilCore
import PaperVeilPipeline
import Testing

@Suite struct PropagationTests {
    /// Regression (GUI acceptance run 2026-11-01): a bare header line "Erika Mustermann"
    /// without label context stayed unredacted when only rules were active.
    @Test func everyOccurrenceOfADetectedNameIsProposedRulesOnly() async throws {
        let url = Repo.fixtures.appendingPathComponent("F01-arztbrief.pdf")
        let a = try await DocumentPipeline().analyze(url: url, documentID: .generate(), blocklist: nil, llm: nil)
        for page in a.pages {
            let ns = page.text as NSString
            var range = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: "Erika Mustermann", options: [], range: range)
                if r.location == NSNotFound { break }
                let rects = page.rects(for: r)
                let covered = a.findings.contains { f in
                    f.pageIndex == page.pageIndex && f.rects.contains { fr in rects.contains { $0.intersects(fr) } }
                }
                #expect(covered, "S. \(page.pageIndex + 1) Offset \(r.location) nicht vorgeschlagen")
                range = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
            }
        }
    }
}

@Suite struct DeduplicationTests {
    @Test func identicalSpotsKeepAllOrigins() {
        let id = DocumentID.generate()
        let r = [PageRect(x: 10, y: 10, width: 50, height: 10)]
        let rule = Finding(documentID: id, pageIndex: 0, rects: r, text: "Erika Mustermann", category: .name, origin: .rule)
        let llm = Finding(documentID: id, pageIndex: 0, rects: r, text: "Erika Mustermann", category: .name, origin: .llm)
        let block = Finding(documentID: id, pageIndex: 0, rects: r, text: "Erika Mustermann", category: .name, origin: .blocklist)
        let merged = DocumentPipeline.deduplicate([block, rule, llm])
        #expect(merged.count == 1)
        #expect(merged[0].origin == .blocklist)
        #expect(merged[0].note == "Auch erkannt: Regel, LLM")
    }
}
