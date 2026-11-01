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
