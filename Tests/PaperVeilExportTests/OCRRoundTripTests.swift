import Foundation
import Testing
import PaperVeilExtraction
import Vision
@testable import PaperVeilExport

@Suite struct OCRRoundTripTests {
    /// Independent OCR proof (Apple Vision, local): after the export the
    /// marker must be unreadable even from the pixels, while the non-redacted
    /// medical line stays readable. The unredacted source is the positive
    /// control showing the marker is OCR-detectable at all.
    @Test func exportedMarkerIsInvisibleToOCRWhileMedicalContentSurvives() async throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let destination = dir.appendingPathComponent("PV-TESTFIX-r1.pdf")
        try TestFixtures.buildSource(source)
        _ = try RasterExporter.export(original: source, findings: TestFixtures.markerFindings(), to: destination)

        let exportText = try await OCR.text(of: destination, page: 1, dpi: 300)
        #expect(!exportText.contains("4711"), "OCR darf den geschwärzten Marker nicht lesen")
        #expect(!exportText.contains("GEHEIM"))
        #expect(exportText.contains("Kalium"), "Die medizinische Zeile muss lesbar bleiben: \(exportText)")

        let sourceText = try await OCR.text(of: source, page: 1, dpi: 300)
        #expect(sourceText.contains("4711"), "Positivkontrolle: Marker im Original lesbar")
        #expect(sourceText.contains("Kalium"))
    }
}

enum OCR {
    /// Renders `page` (1-based) and recognizes text with Vision, de-DE.
    static func text(of url: URL, page: Int, dpi: Double) async throws -> String {
        guard let document = CGPDFDocument(url as CFURL),
              let pdfPage = document.page(at: page),
              let bitmap = PageBitmap(page: pdfPage, dpi: dpi),
              let image = bitmap.image
        else { return "" }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "de-DE")]
        request.usesLanguageCorrection = false
        let observations = try await OCRCompute.perform(request, on: image)
        return observations
            .map { $0.topCandidates(1).first?.string ?? "" }
            .joined(separator: "\n")
    }
}
