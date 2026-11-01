import Foundation
import PDFKit
import Testing
import PaperVeilCore
@testable import PaperVeilExport

@Suite struct ExportInspectorTests {
    /// The inspector must *see* every side channel of the source document —
    /// this is the positive control for the export assertions.
    @Test func inspectorSurveysSourceDocument() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        try TestFixtures.buildSource(source)

        let report = ExportInspector.inspect(url: source)

        #expect(report.pageCount == 5)
        #expect(report.structureParsingComplete)
        #expect(report.extractedText.contains(TestFixtures.marker), "Marker muss im Original extrahierbar sein")
        #expect(report.infoDictionary["Title"]?.contains(TestFixtures.marker) == true)
        #expect(report.infoDictionary["Author"] == "Max Muster")
        #expect(report.catalogKeys.contains("AcroForm"))
        #expect(report.catalogKeys.contains("Names"))
        #expect(report.hasForm)
        #expect(report.hasEmbeddedFiles)
        #expect(report.annotationCount == 3, "Notiz, Freitext und Formularfeld zählen als Annotationen")
        #expect(report.perPageImageCount == [0, 0, 0, 0, 0])
        #expect(!report.isEncrypted)
        #expect(!report.hasOutlines)
        #expect(!report.hasOpenAction)
    }

    /// After the export, the marker must be nowhere: not in text, metadata,
    /// catalog, annotations, forms or attachments — and each page must be
    /// exactly one image.
    @Test func inspectorFindsNoMarkerInExport() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let destination = dir.appendingPathComponent("PV-TESTFIX-r1.pdf")
        try TestFixtures.buildSource(source)
        _ = try RasterExporter.export(original: source, findings: TestFixtures.markerFindings(), to: destination, dpi: 150)

        let report = ExportInspector.inspect(url: destination)

        #expect(report.pageCount == 5)
        #expect(report.structureParsingComplete, "\(report.notes)")
        #expect(report.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(report.annotationCount == 0)
        #expect(!report.hasForm)
        #expect(!report.hasEmbeddedFiles)
        #expect(!report.hasOutlines)
        #expect(!report.hasOpenAction)
        #expect(!report.isEncrypted)
        #expect(report.perPageImageCount == [1, 1, 1, 1, 1])
        for forbidden in ["AcroForm", "Names", "OpenAction", "AA", "JavaScript", "Outlines", "EmbeddedFiles"] {
            #expect(!report.catalogKeys.contains(forbidden), "Katalog enthält /\(forbidden)")
        }
        for (key, value) in report.infoDictionary {
            #expect(!value.contains("4711"), "Marker in Metadaten: \(key)")
            #expect(!value.contains("GEHEIM"), "Marker in Metadaten: \(key)")
        }
        // The full marker does not appear verbatim anywhere in the raw bytes
        // either (only structures are checked above; this is a bonus check).
        let raw = try Data(contentsOf: destination)
        #expect(raw.firstRange(of: Data("GEHEIM-4711".utf8)) == nil)
    }
}
