import Foundation
import PaperVeilCore
import Testing
@testable import PaperVeilDetection

private let docID = DocumentID(rawValue: "PV-TEST")

/// Builds a synthetic page: one word per space-separated token, one line per
/// array element, deterministic rects.
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

private func detect(_ lines: [String], pageIndex: Int = 0) -> [Finding] {
    RuleDetector().detect(in: [makePage(lines, pageIndex: pageIndex)], documentID: docID)
}

@Suite
struct RulesTests {

    // MARK: - E-mail

    @Test func emailDetected() throws {
        let findings = detect(["Kontakt: erika.mustermann@example.de",
                               "Sekretariat info@praxis-beispielburg.example"])
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.category == .email && $0.origin == .rule && $0.decision == .proposed })
        #expect(findings.map(\.text) == ["erika.mustermann@example.de", "info@praxis-beispielburg.example"])
    }

    // MARK: - Phone

    @Test func phoneWithInternationalPrefixNeedsNoContext() throws {
        let plus = detect(["Bitte rufen Sie +49 40 1234567 an"])
        #expect(plus.count == 1)
        #expect(try #require(plus.first).category == .phone)
        #expect(plus.first?.text == "+49 40 1234567")

        let zeros = detect(["Rückruf 0049 40 123456 erbeten"])
        #expect(zeros.count == 1)
        #expect(zeros.first?.text == "0049 40 123456")

        #expect(detect(["+49301234567"]).count == 1)
    }

    @Test func phoneRequiresContextForLocalNumbers() {
        // 0-prefix numbers without context must not be flagged.
        #expect(detect(["Rückruf unter 040 123456 erbeten"]).isEmpty)
        #expect(detect(["0170 555666"]).isEmpty)
        #expect(detect(["Notruf 112"]).isEmpty)
    }

    @Test func phoneWithContextMenuVariants() throws {
        let cases: [(label: String, line: String, expected: String)] = [
            ("Tel", "Tel: 040 1234567", "040 1234567"),
            ("Telefon", "Telefon: 040/1234-5678", "040/1234-5678"),
            ("Fax", "Fax: (030) 1234-5678", "(030) 1234-5678"),
            ("Mobil", "Mobil: 0170 1234567", "0170 1234567"),
            ("Handy", "Handy: 0171/2345678", "0171/2345678"),
            ("Tel. Nr.", "Tel. Nr.: 0221 998765", "0221 998765"),
            ("Fax-Nr.", "Fax-Nr.: (089) 12345-6", "(089) 12345-6"),
            ("Telefonnummer", "Telefonnummer: 0351 987654", "0351 987654"),
        ]
        for testCase in cases {
            let findings = detect([testCase.line])
            let finding = try #require(findings.first, "expected a phone finding for: \(testCase.line)")
            #expect(finding.category == .phone)
            #expect(finding.text == testCase.expected,
                    "label \(testCase.label): got \(finding.text)")
        }
    }

    @Test func phoneLabelIsNotRedacted() throws {
        let findings = detect(["Tel: 040 1234567"])
        let finding = try #require(findings.first)
        #expect(finding.text.hasPrefix("0"))
        #expect(!finding.text.contains("Tel"))
    }

    // MARK: - Postal address

    @Test func streetWithHouseNumber() throws {
        let cases = ["Musterstraße 12", "Musterstr. 5", "Lindenweg 7", "Rosenallee 3",
                     "Hauptplatz 4", "Schulgasse 2", "Wasserdamm 6", "Straße 1"]
        for street in cases {
            let findings = detect(["Wohnhaft \(street), Ort"])
            let finding = try #require(findings.first, "expected a street finding for: \(street)")
            #expect(finding.category == .address)
            #expect(finding.text == street)
        }
    }

    @Test func streetWithoutHouseNumberNotFlagged() {
        #expect(detect(["Wir fahren die Musterstraße entlang"]).isEmpty)
        #expect(detect(["Wohnhaft in der Lindenweg-Gegend"]).isEmpty)
    }

    @Test func streetAcrossLineBreak() throws {
        let findings = detect(["Musterstraße", "12"])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.text == "Musterstraße\n12")
        #expect(finding.rects.count == 2)
    }

    @Test func streetWithHyphenatedLineBreak() throws {
        let findings = detect(["Muster-", "straße 12"])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.text.hasPrefix("Muster-"))
        #expect(finding.rects.count == 2)
    }

    @Test func plzOrt() throws {
        let findings = detect(["12345 Beispielburg"])
        #expect(findings.count == 1)
        #expect(findings.first?.category == .address)
        #expect(findings.first?.text == "12345 Beispielburg")

        // Two-word city.
        let twoWords = detect(["12345 Bad Beispielburg"])
        #expect(twoWords.count == 1)
        #expect(try #require(twoWords.first).text == "12345 Bad Beispielburg")

        // Across a line break.
        let across = detect(["12345", "Beispielburg"])
        #expect(across.count == 1)
        #expect(try #require(across.first).text == "12345\nBeispielburg")
        #expect(across.first?.rects.count == 2)
    }

    @Test func plzDoesNotCaptureTheNextLine() {
        // The second city word must be on the same line: "Versichertennr." is
        // the first word of the NEXT line and must not be swallowed.
        let page = makePage(["Wohnhaft 12345 Beispielburg", "Versichertennr.: A123456789"])
        let findings = RuleDetector().detect(in: [page], documentID: docID)
        let address = findings.filter { $0.category == .address }
        #expect(address.count == 1)
        #expect(address.first?.text == "12345 Beispielburg")
    }

    @Test func plzRequiresCapitalisedCity() {
        #expect(detect(["12345 beispielburg"]).isEmpty)
    }

    @Test func implausiblePlzNotFlagged() {
        #expect(detect(["00123 Beispielburg"]).isEmpty)
        #expect(detect(["1234 Beispielburg"]).isEmpty)
    }

    // MARK: - Birth date

    @Test func birthDateOnlyWithContext() throws {
        let cases: [(line: String, date: String)] = [
            ("geb. 12.03.1980", "12.03.1980"),
            ("Geboren am 03.02.1956", "03.02.1956"),
            ("Geburtsdatum: 15.06.1978", "15.06.1978"),
            ("Geb.-Dat.: 01.02.1930", "01.02.1930"),
            ("* 12.03.1980", "12.03.1980"),
            ("geb. 3.2.80", "3.2.80"),
        ]
        for testCase in cases {
            let findings = detect([testCase.line])
            let finding = try #require(findings.first, "expected a birth date finding for: \(testCase.line)")
            #expect(finding.category == .birthDate)
            #expect(finding.text == testCase.date)
        }
    }

    @Test func birthDateContextLabelIsNotRedacted() throws {
        let findings = detect(["Geburtsdatum: 15.06.1978"])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.text == "15.06.1978")
        #expect(!finding.text.contains("Geburtsdatum"))
    }

    @Test func birthDateAcrossLineBreak() throws {
        let findings = detect(["Geburtsdatum:", "15.06.1978"])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.text == "15.06.1978")
        #expect(finding.rects.count == 1)
    }

    @Test func invalidBirthDateNotFlagged() {
        #expect(detect(["geb. 32.13.1980"]).isEmpty)
        #expect(detect(["geb. 00.01.1980"]).isEmpty)
    }

    // MARK: - Insurance number

    @Test func kvnrStructural() throws {
        let findings = detect(["Versicherung A123456789"])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.category == .insuranceNumber)
        #expect(finding.text == "A123456789")

        let spaced = detect(["Die A 123 456 789 steht oben"])
        #expect(spaced.count == 1)
        #expect(spaced.first?.text == "A 123 456 789")
    }

    @Test func kvnrStructuralNegatives() {
        #expect(detect(["A12345678"]).isEmpty)      // only 8 digits
        #expect(detect(["A1234567890"]).isEmpty)    // 10 digits
        #expect(detect(["123456789"]).isEmpty)      // no letter
        #expect(detect(["Wert 4,2 mmol/l"]).isEmpty)
    }

    @Test func insuranceContextLabels() throws {
        let cases: [(line: String, value: String)] = [
            ("Versichertennr.: A123456789", "A123456789"),
            ("Versicherten-Nr.: B222333444", "B222333444"),
            ("Vers.-Nr.: X987654321", "X987654321"),
            ("KV-Nr.: 1234567890", "1234567890"),
        ]
        for testCase in cases {
            let findings = detect([testCase.line])
            let finding = try #require(findings.first, "expected an insurance finding for: \(testCase.line)")
            #expect(finding.category == .insuranceNumber)
            #expect(finding.text == testCase.value)
        }
    }

    @Test func insuranceContextWithoutDigitNotFlagged() {
        #expect(detect(["Versichertennr. unbekannt"]).isEmpty)
        #expect(detect(["KV-Nr. folgt"]).isEmpty)
    }

    // MARK: - Patient/case IDs

    @Test func patientIDContextLabels() throws {
        let cases: [(line: String, value: String)] = [
            ("Pat.-Nr.: 4711", "4711"),
            ("Patienten-ID: P12345", "P12345"),
            ("Fall-Nr.: 202400123", "202400123"),
            ("Aufnahme-Nr.: 23-456", "23-456"),
        ]
        for testCase in cases {
            let findings = detect([testCase.line])
            let finding = try #require(findings.first, "expected a patient ID finding for: \(testCase.line)")
            #expect(finding.category == .patientID)
            #expect(finding.text == testCase.value)
        }
    }

    @Test func patientIDNegatives() {
        #expect(detect(["Fall-Nr. folgt"]).isEmpty)
        #expect(detect(["Pat.-Nr.: 12"]).isEmpty) // too short
    }

    // MARK: - Names after salutation/context

    @Test func namesAfterLabels() throws {
        let cases: [(line: String, name: String)] = [
            ("Patient: Erika Mustermann", "Erika Mustermann"),
            ("Patientin: Erika Mustermann", "Erika Mustermann"),
            ("Name: Max Beispielmann", "Max Beispielmann"),
            ("Sehr geehrte Frau Erika Mustermann,", "Erika Mustermann"),
            ("Herr Peter Müller erschien", "Peter Müller"),
        ]
        for testCase in cases {
            let findings = detect([testCase.line])
            let finding = try #require(findings.first, "expected a name finding for: \(testCase.line)")
            #expect(finding.category == .name)
            #expect(finding.text == testCase.name)
        }
    }

    @Test func titlesAreKeptNotRedacted() throws {
        // "Dr. med." stays visible; only the actual name is the identifier.
        let findings = detect(["Frau Dr. med. Sabine Weber"])
        #expect(findings.count == 1)
        #expect(try #require(findings.first).text == "Sabine Weber")

        let double = detect(["Herr Prof. Dr. med. Weber"])
        #expect(double.count == 1)
        #expect(double.first?.text == "Weber")
    }

    @Test func nameStopwordsNotFlagged() {
        #expect(detect(["Patient: Ich wurde 2025 untersucht"]).isEmpty)
        #expect(detect(["Patientin: Bitte zurückmelden"]).isEmpty)
    }

    @Test func noNameFindingsWithoutContext() {
        #expect(detect(["Erika Mustermann erschien zur Untersuchung"]).isEmpty)
        #expect(detect(["Unterzeichnet: Dr. med. Thomas Weber"]).isEmpty)
        #expect(detect(["Ehefrau Petra Müller telefoniert nicht"]).isEmpty)
    }

    // MARK: - Clinical content must not be flagged (B05)

    @Test func labValuesWithDecimalCommaAndMinusNotFlagged() {
        #expect(detect(["Wert -0,5 mmol/l auffällig"]).isEmpty)
        #expect(detect(["Kalium 4,2 mmol/l"]).isEmpty)
        #expect(detect(["Natrium 139 mmol/l"]).isEmpty)
    }

    @Test func referenceRangesNotFlagged() {
        #expect(detect(["Referenzbereich 3,5 - 5,1 mmol/l"]).isEmpty)
        #expect(detect(["Bereich (135 - 145) mmol/l"]).isEmpty)
    }

    @Test func dosagesNotFlagged() {
        #expect(detect(["Dosierung 1-0-1, morgens"]).isEmpty)
        #expect(detect(["500 mg morgens"]).isEmpty)
    }

    @Test func clinicalDatesWithoutBirthContextNotFlagged() {
        #expect(detect(["Untersuchung am 03.02.2025"]).isEmpty)
        #expect(detect(["seit 12.01.2024 beschwerdefrei"]).isEmpty)
        #expect(detect(["Befund vom 03.02.2025, Kontrolle am 12.02.2026"]).isEmpty)
    }

    @Test func icdCodesNotFlagged() {
        #expect(detect(["Diagnose: E11.9 Diabetes mellitus"]).isEmpty)
        #expect(detect(["Zusätzlich Z98.890"]).isEmpty)
    }

    @Test func physicianTitleNotFlagged() {
        #expect(detect(["Ihr Dr. med. Thomas Weber"]).isEmpty)
    }

    // MARK: - Combined, multi-page and geometry

    @Test func realisticLetterMix() {
        let findings = detect([
            "Patient: Erika Mustermann, geb. 12.03.1980",
            "Wohnhaft Musterstraße 12, 12345 Beispielburg",
            "Versichertennr.: A123456789, Tel: 040 1234567",
            "Laborwert 4,2 mmol/l, Referenzbereich 3,5 - 5,1, Diagnose E11.9",
            "Dosierung 1-0-1, 500 mg. Untersuchung am 03.02.2025.",
        ])
        #expect(findings.count == 6)
        let summary = Dictionary(grouping: findings, by: \.category)
            .mapValues { $0.map(\.text) }
        #expect(summary[.name] == ["Erika Mustermann"])
        #expect(summary[.birthDate] == ["12.03.1980"])
        #expect(summary[.address] == ["Musterstraße 12", "12345 Beispielburg"])
        #expect(summary[.insuranceNumber] == ["A123456789"])
        #expect(summary[.phone] == ["040 1234567"])
    }

    @Test func rulesAcrossPages() {
        let pages = [
            makePage(["Mail: erika.mustermann@example.de"], pageIndex: 0),
            makePage(["Natrium 139 mmol/l, seit 12.01.2024 stabil"], pageIndex: 1),
            makePage(["Patient: Max Beispielmann, geb. 01.01.1950"], pageIndex: 2),
        ]
        let findings = RuleDetector().detect(in: pages, documentID: docID)
        // Page 0: e-mail. Page 1: clinical content only. Page 2: name + birth date.
        #expect(findings.count == 3)
        #expect(findings.filter { $0.pageIndex == 0 }.count == 1)
        #expect(findings.filter { $0.pageIndex == 1 }.isEmpty)
        #expect(findings.filter { $0.pageIndex == 2 }.count == 2)
        #expect(findings.allSatisfy { $0.documentID == docID && $0.origin == .rule })
    }

    @Test func rotatedPageIsStillMatched() {
        let page = makeRotatedPage(["Pat.-Nr.: 4711"])
        let findings = RuleDetector().detect(in: [page], documentID: docID)
        #expect(findings.count == 1)
        #expect(findings.first?.text == "4711")
        // The finding carries the (rotated) geometry of the matched word.
        let wordRect = page.words.first { $0.text == "4711" }!.rect
        #expect(findings.first?.rects == [wordRect])
    }
}
