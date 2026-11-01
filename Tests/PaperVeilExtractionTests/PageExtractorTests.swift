import Foundation
import PDFKit
import Testing
import PaperVeilCore
@testable import PaperVeilExtraction

@Suite("PageExtractor")
struct PageExtractorTests {

    private func extract(_ url: URL) async throws -> ExtractionResult {
        try await PageExtractor().extract(url: url, documentID: DocumentID.generate())
    }

    // MARK: - End-to-end

    @Test("Textseite ohne Bild nutzt PDF-Text, ohne Warnungen")
    func textPageUsesPDFText() async throws {
        var factory = try makeFixtureFactory()
        let (url, drawn) = try factory.makeTextPDF(named: "textseite.pdf", lines: [
            ("Befund Patient Müller", CGPoint(x: 72, y: 700)),
        ])
        let result = try await extract(url)

        #expect(result.pages.count == 1)
        #expect(result.warnings.isEmpty)
        let page = result.pages[0]
        #expect(page.words.count == 3)
        #expect(page.words.allSatisfy { $0.source == .pdfText })
        #expect(page.text == "Befund Patient Müller")

        // Geometrie stimmt weiterhin (~2pt).
        let expected = drawn.first { $0.text == "Müller" }!.expectedRect
        let muller = page.words.first { $0.text == "Müller" }!
        #expect(abs(muller.rect.x - expected.minX) <= 2)
        #expect(abs(muller.rect.y - expected.minY) <= 2)
    }

    @Test("Bildseite (Scan) wird per OCR verarbeitet und als abgeleitet markiert")
    func scanPageIsOCRAndWarned() async throws {
        let factory = try makeFixtureFactory()
        let (url, drawn) = try factory.makeScanPDF(
            named: "scanseite.pdf",
            lines: [("Geburtsdatum 12.03.1961 Musterstraße 5", CGPoint(x: 300, y: 3000))]
        )
        let result = try await extract(url)

        #expect(result.pages.count == 1)
        let page = result.pages[0]
        #expect(page.isOCR)
        #expect(page.words.allSatisfy { $0.source == .ocr })

        let ocrWarnings = result.warnings.filter { $0.kind == .ocrOnlyPage }
        #expect(ocrWarnings.count == 1)
        #expect(ocrWarnings[0].pageIndex == 0)
        #expect(ocrWarnings[0].message.contains("OCR"))

        // Sauber gerenderter Scan: keine Warnung über unsichere OCR.
        #expect(!result.warnings.contains { $0.kind == .lowOCRConfidence })

        // Die gesuchten Wörter werden mit überlappender Geometrie gefunden.
        for target in ["Musterstraße", "12.03.1961"] {
            guard let word = page.words.first(where: { $0.text == target }) else {
                Issue.record("Wort '\(target)' fehlt im OCR-Ergebnis: \(page.words.map(\.text))")
                continue
            }
            let expected = drawn.first { $0.text == target }!.expectedRect
            #expect(overlapFraction(of: expected, with: word.rect.cgRect) >= 0.3)
        }
    }

    @Test("Gemischte Seite: PDF-Text und OCR werden zusammengeführt")
    func mixedPageMergesPDFAndOCR() async throws {
        var factory = try makeFixtureFactory()
        let (url, _) = try factory.makeMixedPDF(
            named: "gemischt.pdf",
            pdfText: "Befund Patient Müller",
            pdfTextOrigin: CGPoint(x: 72, y: 700),
            scanText: "Musterstraße 12.03.1961"
        )
        let result = try await extract(url)

        #expect(result.pages.count == 1)
        let page = result.pages[0]
        let pdfWords = page.words.filter { $0.source == .pdfText }
        let ocrWords = page.words.filter { $0.source == .ocr }
        #expect(pdfWords.map(\.text) == ["Befund", "Patient", "Müller"])
        #expect(!ocrWords.isEmpty)

        // Lesereihenfolge: PDF-Zeile oben (y=700) vor OCR-Zeile unten (y≈300).
        #expect(pdfWords.allSatisfy { $0.line == 0 })
        #expect(ocrWords.allSatisfy { $0.line == 1 })
        #expect(page.text.hasPrefix("Befund Patient Müller\n"))

        // Gemischte Seite ist abgeleiteten Texts wegen zu markieren.
        #expect(result.warnings.contains { $0.kind == .ocrOnlyPage && $0.pageIndex == 0 })
    }

    @Test("Originaldatei bleibt nach Extraktion unverändert")
    func originalFileUnchanged() async throws {
        let factory = try makeFixtureFactory()
        let (url, _) = try factory.makeScanPDF(
            named: "original-scan.pdf",
            lines: [("Geburtsdatum 12.03.1961 Musterstraße 5", CGPoint(x: 300, y: 3000))]
        )
        let before = try SHA256Hex.of(fileAt: url)
        _ = try await extract(url)
        let after = try SHA256Hex.of(fileAt: url)
        #expect(before == after)
    }

    @Test("Extraktion ist abbrechbar")
    func extractionIsCancellable() async throws {
        var factory = try makeFixtureFactory()
        let (url, _) = try factory.makeTextPDF(named: "abbrechbar.pdf", lines: [
            ("Befund Patient Müller", CGPoint(x: 72, y: 700)),
        ])
        let gate = Gate()
        let extractor = PageExtractor()
        let documentID = DocumentID.generate()

        // Task parkt im Gate; wir brechen ab, bevor die Extraktion beginnt,
        // und geben erst danach frei — deterministisch wiederholbar.
        let task = Task {
            await gate.wait()
            _ = try await extractor.extract(url: url, documentID: documentID)
        }
        task.cancel()
        gate.signal()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("Mehrzeiliges Dokument verarbeitet alle Seiten")
    func multiPageDocument() async throws {
        let factory = try makeFixtureFactory()
        let url = factory.directory.appendingPathComponent("mehrseitig.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        let attr: [NSAttributedString.Key: Any] = [
            .font: factory.font,
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        for i in 0..<3 {
            context.beginPDFPage(nil)
            let attributed = CFAttributedStringCreate(
                nil, "Seite drei Text \(i)" as CFString, attr as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        let result = try await extract(url)
        #expect(result.pages.count == 3)
        #expect(result.pages[0].text == "Seite drei Text 0")
        #expect(result.pages[1].text == "Seite drei Text 1")
        #expect(result.pages[2].text == "Seite drei Text 2")
        #expect(result.warnings.isEmpty)
    }
}

@Suite("PageExtractor unit logic")
struct PageExtractorLogicTests {
    private func word(_ text: String, rect: CGRect, source: TextSource = .pdfText,
                      confidence: Double = 1, line: Int = 0) -> TextWord {
        TextWord(text: text, rect: PageRect(rect), source: source, confidence: confidence, line: line)
    }

    @Test("Sinnvoller Text wird erkannt, Fragmente nicht")
    func meaningfulText() {
        let real = (0..<3).map { word("Wort\($0)", rect: CGRect(x: 0, y: 0, width: 10, height: 5)) }
        #expect(PageExtractor.hasMeaningfulText(real))
        // Nur eine Seitenzahl ist kein sinnvoller Text.
        #expect(!PageExtractor.hasMeaningfulText([word("3", rect: CGRect(x: 0, y: 0, width: 4, height: 5))]))
        #expect(!PageExtractor.hasMeaningfulText([]))
    }

    @Test("Doppelte OCR-Wörter über bestehenden PDF-Wörtern werden verworfen")
    func dedupeOverlappingOCRWords() {
        let pdfRect = CGRect(x: 100, y: 700, width: 90, height: 12)
        let pdf = [word("Befund", rect: pdfRect)]
        let duplicates = [
            word("Befund", rect: pdfRect.insetBy(dx: 2, dy: 1), source: .ocr, confidence: 0.9),
            word("Befund", rect: pdfRect.offsetBy(dx: 3, dy: 2), source: .ocr, confidence: 0.9),
        ]
        let distinct = [
            word("Musterstraße", rect: CGRect(x: 100, y: 300, width: 90, height: 12), source: .ocr, confidence: 0.9),
        ]
        let kept = PageExtractor.deduplicated(ocrWords: duplicates + distinct, against: pdf)
        #expect(kept.map(\.text) == ["Musterstraße"])
        // Ohne PDF-Wörter bleibt alles erhalten.
        #expect(PageExtractor.deduplicated(ocrWords: duplicates, against: []).count == 2)
    }

    @Test("Warnungen: OCR-Seite und geringe Konfidenz")
    func warningsForWords() {
        let certainOCR = word("Befund", rect: CGRect(x: 0, y: 0, width: 10, height: 5), source: .ocr, confidence: 0.9)
        let uncertainOCR = word("Befund", rect: CGRect(x: 0, y: 0, width: 10, height: 5), source: .ocr, confidence: 0.3)
        let pdfOnly = word("Befund", rect: CGRect(x: 0, y: 0, width: 10, height: 5))

        #expect(PageExtractor.warnings(for: [pdfOnly], pageIndex: 0).isEmpty)
        let onlyOCR = PageExtractor.warnings(for: [certainOCR], pageIndex: 2)
        #expect(onlyOCR.count == 1)
        #expect(onlyOCR[0].kind == .ocrOnlyPage)
        #expect(onlyOCR[0].pageIndex == 2)

        let withLow = PageExtractor.warnings(for: [certainOCR, uncertainOCR], pageIndex: 1)
        #expect(withLow.count == 2)
        #expect(withLow.contains { $0.kind == .lowOCRConfidence && $0.pageIndex == 1 })
    }

    @Test("Zusammenführung ordnet PDF- und OCR-Zeilen nach Position")
    func mergedReadingOrder() {
        let geometry = PageGeometry(crop: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        let pdfTop = word("Befund", rect: CGRect(x: 72, y: 700, width: 60, height: 12), line: 0)
        let ocrBottom = [
            word("Musterstraße", rect: CGRect(x: 72, y: 300, width: 60, height: 12), source: .ocr, line: 0),
            word("12.03.1961", rect: CGRect(x: 140, y: 300, width: 60, height: 12), source: .ocr, line: 0),
        ]
        let merged = PageExtractor.merged(pdfWords: [pdfTop], ocrWords: ocrBottom, geometry: geometry)
        #expect(merged.map(\.text) == ["Befund", "Musterstraße", "12.03.1961"])
        #expect(merged.map(\.line) == [0, 1, 1])

        // Nur PDF-Wörter bzw. nur OCR-Wörter bleiben unverändert.
        #expect(PageExtractor.merged(pdfWords: [pdfTop], ocrWords: [], geometry: geometry).count == 1)
        #expect(PageExtractor.merged(pdfWords: [], ocrWords: ocrBottom, geometry: geometry).count == 2)
    }

    @Test("Bildanalyse: Scanseite gilt als großes Bild, Textseite nicht")
    func imageAnalyzerClassification() throws {
        let factory = try makeFixtureFactory()
        let (scanURL, _) = try factory.makeScanPDF(
            named: "bild.pdf",
            lines: [("Geburtsdatum 12.03.1961 Musterstraße 5", CGPoint(x: 300, y: 3000))]
        )
        var textFactory = try makeFixtureFactory()
        let (textURL, _) = try textFactory.makeTextPDF(named: "text.pdf", lines: [
            ("Befund Patient Müller", CGPoint(x: 72, y: 700)),
        ])

        guard let scanPage = PDFDocument(url: scanURL)?.page(at: 0),
              let textPage = PDFDocument(url: textURL)?.page(at: 0) else {
            Issue.record("Fixtures nicht ladbar"); return
        }
        let analyzer = PageImageAnalyzer()
        #expect(analyzer.containsLargeImage(page: scanPage))
        #expect(!analyzer.containsLargeImage(page: textPage))
        #expect(analyzer.largestImageFraction(page: scanPage) > 0.9)
        #expect(analyzer.largestImageFraction(page: textPage) < 0.1)
    }
}
