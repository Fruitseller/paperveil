import Foundation
import PDFKit
import Testing
import PaperVeilCore
@testable import PaperVeilExtraction

@Suite("PDFTextExtractor")
struct PDFTextExtractorTests {

    private func extractWords(url: URL) throws -> [TextWord] {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            Issue.record("PDF konnte nicht geladen werden")
            return []
        }
        return PDFTextExtractor().extractWords(page: page, pageIndex: 0)
    }

    @Test("Wort an bekannter Position liefert Rechteck mit ~2pt Genauigkeit")
    func wordGeometryMatchesDrawPosition() throws {
        var factory = try makeFixtureFactory()
        let (url, drawn) = try factory.makeTextPDF(
            named: "position.pdf",
            lines: [("Geburtsdatum", CGPoint(x: 100, y: 700))]
        )
        let words = try extractWords(url: url)
        #expect(words.count == 1)
        guard let word = words.first else { return }
        #expect(word.text == "Geburtsdatum")
        #expect(word.source == .pdfText)
        #expect(word.confidence == 1)

        let expected = drawn[0].expectedRect
        let tolerance: CGFloat = 2
        #expect(abs(word.rect.x - expected.minX) <= tolerance, "x: \(word.rect.x) vs \(expected.minX)")
        #expect(abs(word.rect.y - expected.minY) <= tolerance, "y: \(word.rect.y) vs \(expected.minY)")
        #expect(abs(word.rect.width - expected.width) <= tolerance, "breite: \(word.rect.width) vs \(expected.width)")
        #expect(abs(word.rect.height - expected.height) <= tolerance, "höhe: \(word.rect.height) vs \(expected.height)")
    }

    @Test("Dieselbes Wort zweimal auf der Seite ergibt zwei verschiedene Rechtecke")
    func repeatedWordYieldsDistinctRects() throws {
        var factory = try makeFixtureFactory()
        let (url, drawn) = try factory.makeTextPDF(named: "wiederholt.pdf", lines: [
            ("Musterstraße", CGPoint(x: 100, y: 700)),
            ("Musterstraße", CGPoint(x: 140, y: 500)),
        ])
        let words = try extractWords(url: url)
        let occurrences = words.filter { $0.text == "Musterstraße" }
        #expect(occurrences.count == 2)

        for (word, drawnWord) in zip(occurrences, drawn) {
            #expect(abs(word.rect.x - drawnWord.expectedRect.minX) <= 2)
            #expect(abs(word.rect.y - drawnWord.expectedRect.minY) <= 2)
        }
        #expect(occurrences[0].rect != occurrences[1].rect)
        // Zwei Zeilen → zwei Zeilennummern in Lesereihenfolge.
        #expect(occurrences[0].line == 0 && occurrences[1].line == 1)
    }

    @Test("Seite mit /Rotate 90 liefert mediaBox-Koordinaten der Zeichnung")
    func rotatedPageStillYieldsMediaBoxRects() throws {
        var factory = try makeFixtureFactory()
        let (url, drawn) = try factory.makeTextPDF(
            named: "gedreht-quelle.pdf",
            lines: [("Geburtsdatum", CGPoint(x: 100, y: 700))]
        )
        let rotated = try factory.rotatedCopy(of: url, rotation: 90, named: "gedreht.pdf")
        let words = try extractWords(url: rotated)
        #expect(words.count == 1)
        guard let word = words.first else { return }

        // /Rotate ist gesetzt, die Geometrie bleibt im unrotierten Seitenraum.
        guard let document = PDFDocument(url: rotated), let page = document.page(at: 0) else {
            Issue.record("gedrehtes PDF nicht ladbar"); return
        }
        #expect(page.rotation == 90)
        let expected = drawn[0].expectedRect
        #expect(abs(word.rect.x - expected.minX) <= 2, "x: \(word.rect.x) vs \(expected.minX)")
        #expect(abs(word.rect.y - expected.minY) <= 2, "y: \(word.rect.y) vs \(expected.minY)")
        #expect(abs(word.rect.width - expected.width) <= 2)
        #expect(abs(word.rect.height - expected.height) <= 2)
    }

    @Test("Mehrere Zeilen werden mit Zeilennummern und Zeilenumbrüchen abgebildet")
    func multiLineTextIsReconstructed() throws {
        var factory = try makeFixtureFactory()
        let (url, _) = try factory.makeTextPDF(named: "mehrzeilig.pdf", lines: [
            ("Laborwert 42,5 mg/dl", CGPoint(x: 72, y: 700)),
            ("Referenzbereich bis 5,0", CGPoint(x: 72, y: 650)),
        ])
        let pages = PDFTextExtractor().extract(from: PDFDocument(url: url)!)
        #expect(pages.count == 1)
        let page = pages[0]
        #expect(page.text == "Laborwert 42,5 mg/dl\nReferenzbereich bis 5,0")
        #expect(page.words.count == 6)
        #expect(page.words[0].line == 0)
        #expect(page.words[2].line == 0)
        #expect(page.words[3].line == 1)
        #expect(page.words[5].line == 1)
    }

    @Test("Bildseite ohne Textebene liefert keine PDF-Wörter")
    func scanPageHasNoPDFWords() throws {
        let factory = try makeFixtureFactory()
        let (url, _) = try factory.makeScanPDF(
            named: "nur-bild.pdf",
            lines: [("Geburtsdatum 12.03.1961 Musterstraße 5", CGPoint(x: 300, y: 3000))]
        )
        #expect(try extractWords(url: url).isEmpty)
    }
}
