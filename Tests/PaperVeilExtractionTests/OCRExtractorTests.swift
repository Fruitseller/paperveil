import Foundation
import PDFKit
import Testing
import PaperVeilCore
@testable import PaperVeilExtraction

@Suite("OCRExtractor", .requiresOCR)
struct OCRExtractorTests {

    @Test("Bildseite wird per OCR erkannt; Wörter überlappen die Zeichnungsposition",
          arguments: ["Musterstraße", "12.03.1961"])
    func scanPageOCRMapsBackToDrawPosition(targetWord: String) async throws {
        let factory = try makeFixtureFactory()
        let scanText = "Geburtsdatum 12.03.1961 Musterstraße 5"
        let (url, drawn) = try factory.makeScanPDF(
            named: "scan.pdf",
            lines: [(scanText, CGPoint(x: 300, y: 3000))]
        )
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            Issue.record("Scan-PDF nicht ladbar"); return
        }

        let words = try await OCRExtractor().extractWords(page: page, pageIndex: 0)
        #expect(!words.isEmpty)

        guard let ocrWord = words.first(where: { $0.text == targetWord }) else {
            Issue.record("OCR-Wort '\(targetWord)' nicht erkannt: \(words.map(\.text))")
            return
        }
        #expect(ocrWord.source == .ocr)
        #expect(ocrWord.confidence > 0)

        let expected = drawn.first { $0.text == targetWord }!.expectedRect
        let overlap = overlapFraction(of: expected, with: ocrWord.rect.cgRect)
        #expect(overlap >= 0.3, "OCR-rect \(ocrWord.rect.cgRect) überlappt erwartete Position \(expected) nur zu \(overlap)")

        // Alle OCR-Rechtecke liegen innerhalb der Seite (mediaBox-Raum).
        for word in words {
            #expect(word.rect.x >= -1 && word.rect.y >= -1)
            #expect(word.rect.cgRect.maxX <= 613 && word.rect.cgRect.maxY <= 793)
        }
    }

    @Test("OCR zweier Scan-Zeilen erhält Lesereihenfolge und Zeilennummern")
    func scanLineOrderAndLineNumbers() async throws {
        let factory = try makeFixtureFactory()
        let (url, _) = try factory.makeScanPDF(named: "zwei-zeilen.pdf", lines: [
            ("Erste Zeile Alpha", CGPoint(x: 300, y: 3000)),
            ("Zweite Zeile Beta", CGPoint(x: 300, y: 2900)),
        ])
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            Issue.record("Scan-PDF nicht ladbar"); return
        }
        let words = try await OCRExtractor().extractWords(page: page, pageIndex: 0)

        let firstLine = words.filter { $0.line == 0 }.map(\.text)
        let secondLine = words.filter { $0.line == 1 }.map(\.text)
        #expect(firstLine == ["Erste", "Zeile", "Alpha"], "Zeile 0: \(firstLine)")
        #expect(secondLine == ["Zweite", "Zeile", "Beta"], "Zeile 1: \(secondLine)")
    }

    @Test("OCR auf um 90° gedrehter Seite bildet auf unrotierte mediaBox-Koordinaten zurück")
    func rotatedPageOCRMapping() async throws {
        var factory = try makeFixtureFactory()
        let (url, _) = try factory.makeTextPDF(named: "quelle.pdf", lines: [
            ("Erste Zeile Alpha", CGPoint(x: 100, y: 700)),
            ("Zweite Zeile Beta", CGPoint(x: 100, y: 650)),
        ])
        let rotated = try factory.rotatedCopy(of: url, rotation: 90, named: "gedreht.pdf")
        guard let document = PDFDocument(url: rotated), let page = document.page(at: 0) else {
            Issue.record("gedrehtes PDF nicht ladbar"); return
        }
        #expect(page.rotation == 90)

        // Referenz: PDF-Textextraktion im unrotierten Seitenraum.
        let pdfWords = PDFTextExtractor().extractWords(page: page, pageIndex: 0)
        #expect(!pdfWords.isEmpty)
        let ocrWords = try await OCRExtractor().extractWords(page: page, pageIndex: 0)
        #expect(!ocrWords.isEmpty)

        // Jedes erkannte Wort muss in der Nähe des zugehörigen PDF-Wortes liegen.
        // Wörter können auf der Seite mehrfach vorkommen — zugeordnet wird das
        // geometrisch nächste PDF-Wort mit gleichem Text.
        func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            abs(a.midX - b.midX) + abs(a.midY - b.midY)
        }
        for ocr in ocrWords {
            let candidates = pdfWords.filter { $0.text == ocr.text }
            guard let nearest = candidates.min(by: {
                centerDistance($0.rect.cgRect, ocr.rect.cgRect) < centerDistance($1.rect.cgRect, ocr.rect.cgRect)
            }) else {
                Issue.record("OCR-Wort '\(ocr.text)' hat kein PDF-Gegenstück"); continue
            }
            let overlap = overlapFraction(of: nearest.rect.cgRect, with: ocr.rect.cgRect)
            #expect(overlap >= 0.2, "'\(ocr.text)': OCR \(ocr.rect.cgRect) vs PDF \(nearest.rect.cgRect)")
        }
    }

    @Test("OCR mit verschobenem cropBox bildet korrekt zurück")
    func cropBoxOffsetOCRMapping() async throws {
        var factory = try makeFixtureFactory()
        let (url, drawn) = try factory.makeTextPDF(named: "quelle.pdf", lines: [
            ("Geburtsdatum", CGPoint(x: 100, y: 700))
        ])
        let crop = CGRect(x: 50, y: 600, width: 400, height: 150)
        let cropped = try factory.croppedCopy(of: url, cropBox: crop, named: "beschnitten.pdf")
        guard let document = PDFDocument(url: cropped), let page = document.page(at: 0) else {
            Issue.record("beschnittenes PDF nicht ladbar"); return
        }
        #expect(page.bounds(for: .cropBox) == crop)

        let words = try await OCRExtractor().extractWords(page: page, pageIndex: 0)
        guard let word = words.first else {
            Issue.record("OCR findet im cropBox-Bereich nichts"); return
        }
        #expect(word.text == "Geburtsdatum")
        let expected = drawn[0].expectedRect
        let overlap = overlapFraction(of: expected, with: word.rect.cgRect)
        #expect(overlap >= 0.3, "OCR \(word.rect.cgRect) vs erwartet \(expected)")
    }
}
