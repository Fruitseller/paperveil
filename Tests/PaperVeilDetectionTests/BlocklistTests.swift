import Foundation
import PaperVeilCore
import Testing
@testable import PaperVeilDetection

private let docID = DocumentID(rawValue: "PV-TEST")

/// Builds a synthetic page: one word per space-separated token, one line per
/// array element, deterministic rects (words left to right, lines top to
/// bottom).
private func makePage(_ lines: [String], pageIndex: Int = 0) -> PageText {
    var words: [TextWord] = []
    for (lineIndex, line) in lines.enumerated() {
        var x = 50.0
        for token in line.split(separator: " ", omittingEmptySubsequences: true) {
            let text = String(token)
            let width = Double(text.utf16.count) * 5.5
            words.append(TextWord(text: text,
                                  rect: PageRect(x: x, y: 750 - Double(lineIndex) * 20, width: width, height: 10),
                                  source: .pdfText,
                                  confidence: 1.0,
                                  line: lineIndex))
            x += width + 5
        }
    }
    return PageText(pageIndex: pageIndex, words: words)
}

/// Like `makePage`, but with tall, thin word rects as on a 90° rotated page —
/// detection must not care about rect orientation.
private func makeRotatedPage(_ lines: [String]) -> PageText {
    var words: [TextWord] = []
    for (lineIndex, line) in lines.enumerated() {
        var y = 100.0
        for token in line.split(separator: " ", omittingEmptySubsequences: true) {
            let text = String(token)
            let height = Double(text.utf16.count) * 5.5
            words.append(TextWord(text: text,
                                  rect: PageRect(x: 60 + Double(lineIndex) * 20, y: y, width: 10, height: height),
                                  source: .ocr,
                                  confidence: 0.95,
                                  line: lineIndex))
            y += height + 5
        }
    }
    return PageText(pageIndex: 0, words: words)
}

private func tempFileURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("paperveil-blocklist-\(UUID().uuidString)-\(name).json")
}

@Suite
struct BlocklistTests {

    // MARK: - Persistence

    @Test func saveAndLoadRoundTrip() throws {
        let blocklist = Blocklist(entries: [
            .init(value: "Erika Mustermann", category: .name, variants: ["E. Mustermann"]),
            .init(value: "A123456789", category: .insuranceNumber),
        ])
        let url = tempFileURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }

        try blocklist.save(to: url)
        #expect(try Blocklist.load(from: url) == blocklist)

        // Overwriting an existing file works (atomic write).
        try blocklist.save(to: url)
        #expect(try Blocklist.load(from: url) == blocklist)
    }

    @Test func loadAcceptsArrayFormAndOmittedFields() throws {
        let url = tempFileURL("array-form")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"[{"value": "Mustermann", "category": "name"}]"#
        try json.data(using: .utf8)!.write(to: url)
        let loaded = try Blocklist.load(from: url)
        #expect(loaded.entries == [Blocklist.Entry(value: "Mustermann", category: .name, variants: [])])
    }

    @Test func loadCanonicalObjectForm() throws {
        let url = tempFileURL("object-form")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"entries": [{"value": "A123456789", "category": "insuranceNumber", "variants": ["A 123 456 789"]}]}"#
        try json.data(using: .utf8)!.write(to: url)
        let loaded = try Blocklist.load(from: url)
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries[0].variants == ["A 123 456 789"])
    }

    // MARK: - Matching basics

    @Test func findingsCarryBlocklistOriginAndDecision() throws {
        let blocklist = Blocklist(entries: [.init(value: "Erika Mustermann", category: .name)])
        let page = makePage(["Frau Erika Mustermann,"])
        let findings = blocklist.detect(in: [page], documentID: docID)
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.origin == .blocklist)
        #expect(finding.decision == .proposed)
        #expect(finding.category == .name)
        #expect(finding.documentID == docID)
        #expect(finding.pageIndex == 0)
        #expect(finding.text == "Erika Mustermann")
    }

    @Test func repeatedNamesEachGetTheirOwnFindingWithDistinctRects() throws {
        let blocklist = Blocklist(entries: [.init(value: "Erika Mustermann", category: .name)])
        let page = makePage([
            "Sehr geehrte Frau Erika Mustermann,",
            "wir teilen mit: Erika Mustermann war 2024 in Behandlung.",
        ])
        let findings = blocklist.detect(in: [page], documentID: docID)
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.text == "Erika Mustermann" })
        // One rect per line of the match, and the two occurrences must not
        // share geometry.
        let first = try #require(findings.first)
        let second = try #require(findings.dropFirst().first)
        #expect(first.rects.count == 1)
        #expect(second.rects.count == 1)
        #expect(first.rects != second.rects)
    }

    @Test func caseInsensitive() {
        let blocklist = Blocklist(entries: [.init(value: "Erika Mustermann", category: .name)])
        #expect(blocklist.detect(in: [makePage(["patient erika mustermann"])], documentID: docID).count == 1)
        #expect(blocklist.detect(in: [makePage(["ERIKA MUSTERMANN"])], documentID: docID).count == 1)
    }

    @Test func whitespaceAndLineBreaksBetweenTokens() {
        let blocklist = Blocklist(entries: [.init(value: "Erika Mustermann", category: .name)])
        // Tokens on different lines are still one identifier.
        let acrossLines = makePage(["Erika", "Mustermann"])
        let findings = blocklist.detect(in: [acrossLines], documentID: docID)
        #expect(findings.count == 1)
        #expect(findings.first?.rects.count == 2)
        // Non-breaking whitespace inside a word counts as whitespace too.
        let nbsp = makePage(["Erika\u{00A0}Mustermann"])
        #expect(blocklist.detect(in: [nbsp], documentID: docID).count == 1)
    }

    @Test func hyphenatedLineBreak() {
        let blocklist = Blocklist(entries: [
            .init(value: "Erika Mustermann", category: .name),
            .init(value: "Mustermann", category: .name),
        ])
        // "Muster-\nmann" is "Mustermann" glued back together.
        let page = makePage(["Frau Erika Muster-", "mann, geboren 1950"])
        let findings = blocklist.detect(in: [page], documentID: docID)
        #expect(findings.count == 2)
        let fullName = findings.first { $0.text.hasPrefix("Erika") }
        #expect(fullName != nil)
        #expect(fullName?.text == "Erika Muster-\nmann")
        #expect(fullName?.rects.count == 2)
        let surname = findings.first { $0.text.contains("\n") && $0.text.hasPrefix("Muster-") }
        #expect(surname?.text == "Muster-\nmann")
        #expect(surname?.rects.count == 2)
    }

    @Test func umlautTransliterationBothWays() {
        let blocklist = Blocklist(entries: [.init(value: "Müller", category: .name)])
        #expect(blocklist.detect(in: [makePage(["Thomas Mueller"])], documentID: docID).count == 1)
        #expect(blocklist.detect(in: [makePage(["Thomas Müller"])], documentID: docID).count == 1)

        let translit = Blocklist(entries: [.init(value: "Mueller", category: .name)])
        #expect(translit.detect(in: [makePage(["Thomas Müller"])], documentID: docID).count == 1)
    }

    @Test func nameForms() throws {
        let blocklist = Blocklist(entries: [.init(value: "Erika Mustermann", category: .name),
                                            .init(value: "Max Mustermann", category: .name)])
        // "Nachname, Vorname"
        let reversed = blocklist.detect(in: [makePage(["Mustermann, Erika"])], documentID: docID)
        #expect(reversed.count == 1)
        #expect(try #require(reversed.first).text == "Mustermann, Erika")
        // Initial form "M. Mustermann" — initial of the entry's first name.
        let initial = blocklist.detect(in: [makePage(["M. Mustermann"])], documentID: docID)
        #expect(initial.count == 1)
        #expect(try #require(initial.first).text == "M. Mustermann")
        let initialE = blocklist.detect(in: [makePage(["E. Mustermann"])], documentID: docID)
        #expect(initialE.count == 1)
        #expect(try #require(initialE.first).text == "E. Mustermann")
    }

    @Test func identifierSeparatorVariants() {
        let blocklist = Blocklist(entries: [.init(value: "A123456789", category: .insuranceNumber)])
        let spellings = [
            "A123456789",
            "A123 456 789",
            "A123.456.789",
            "A123/456/789",
            "A123-456-789",
            "Versicherung A 1 2 3 4 5 6 7 8 9",
        ]
        for spelling in spellings {
            #expect(blocklist.detect(in: [makePage([spelling])], documentID: docID).count == 1,
                    "expected a match for \(spelling)")
        }
    }

    @Test func identifierAcrossLineBreak() {
        let blocklist = Blocklist(entries: [.init(value: "A123456789", category: .insuranceNumber)])
        let page = makePage(["Kundennummer A123 456", "789 folgt"])
        let findings = blocklist.detect(in: [page], documentID: docID)
        #expect(findings.count == 1)
        #expect(findings.first?.rects.count == 2)
        #expect(findings.first?.text == "A123 456\n789")
    }

    @Test func wholeWordOnly() {
        let blocklist = Blocklist(entries: [
            .init(value: "Mustermann", category: .name),
            .init(value: "A123456789", category: .insuranceNumber),
        ])
        #expect(blocklist.detect(in: [makePage(["Die Mustermanns kommen"])], documentID: docID).count == 0)
        #expect(blocklist.detect(in: [makePage(["Mustermänner"])], documentID: docID).count == 0)
        #expect(blocklist.detect(in: [makePage(["ID XA123456789"])], documentID: docID).count == 0)
        #expect(blocklist.detect(in: [makePage(["ID A1234567890"])], documentID: docID).count == 0)
        // Positive control: punctuation boundaries are fine.
        #expect(blocklist.detect(in: [makePage(["Die A123456789. wurde geprüft"])], documentID: docID).count == 1)
    }

    @Test func explicitVariantsAreMatched() {
        let blocklist = Blocklist(entries: [
            .init(value: "Erika Mustermann", category: .name,
                  variants: ["E. Mustermann", "Erika M."]),
        ])
        let page = makePage(["E. Mustermann, Erika M. und Erika Mustermann"])
        let findings = blocklist.detect(in: [page], documentID: docID)
        #expect(findings.count == 3)
        #expect(findings.map(\.text).contains("E. Mustermann"))
        #expect(findings.map(\.text).contains("Erika M."))
        // The value itself matches once; the variant "E. Mustermann" hits the
        // same range and is reported only once.
        #expect(findings.filter { $0.text == "Erika Mustermann" }.count == 1)
    }

    @Test func categoryPassesThrough() {
        let blocklist = Blocklist(entries: [
            .init(value: "A123456789", category: .insuranceNumber),
            .init(value: "Max Beispielmann", category: .name),
        ])
        let findings = blocklist.detect(
            in: [makePage(["A123456789 und Max Beispielmann"])],
            documentID: docID
        )
        #expect(findings.count == 2)
        #expect(findings.contains { $0.category == .insuranceNumber && $0.text == "A123456789" })
        #expect(findings.contains { $0.category == .name && $0.text == "Max Beispielmann" })
    }

    @Test func multiPage() {
        let blocklist = Blocklist(entries: [.init(value: "A123456789", category: .insuranceNumber)])
        let pages = [
            makePage(["A123456789"], pageIndex: 0),
            makePage(["kein Treffer hier"], pageIndex: 1),
            makePage(["erneut A123456789"], pageIndex: 2),
        ]
        let findings = blocklist.detect(in: pages, documentID: docID)
        #expect(findings.map(\.pageIndex) == [0, 2])
    }

    @Test func emptyBlocklistYieldsNoFindings() {
        let page = makePage(["Erika Mustermann, A123456789"])
        #expect(Blocklist(entries: []).detect(in: [page], documentID: docID).isEmpty)
        #expect(Blocklist().detect(in: [page], documentID: docID).isEmpty)
    }

    @Test func rotatedPageIsStillMatched() {
        let blocklist = Blocklist(entries: [.init(value: "A123456789", category: .insuranceNumber)])
        let page = makeRotatedPage(["Versicherung A123456789"])
        let findings = blocklist.detect(in: [page], documentID: docID)
        #expect(findings.count == 1)
        // The finding carries the (rotated) geometry of the matched word.
        let wordRect = page.words.first { $0.text == "A123456789" }!.rect
        #expect(findings.first?.rects == [wordRect])
    }
}
