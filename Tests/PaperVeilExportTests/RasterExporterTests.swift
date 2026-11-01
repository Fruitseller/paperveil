import CoreGraphics
import Foundation
import PDFKit
import Testing
import PaperVeilCore
@testable import PaperVeilExport

@Suite struct RasterExporterTests {
    /// Full pipeline: export the fixture, validate independently, check the
    /// export contains nothing but neutral, cleaned images.
    @Test func exportProducesValidatorPassingImageOnlyPDF() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let destination = dir.appendingPathComponent("PV-TESTFIX-r1.pdf")
        try TestFixtures.buildSource(source)
        let sourceHash = try SHA256Hex.of(fileAt: source)
        let findings = TestFixtures.markerFindings()

        let outcome = try RasterExporter.export(original: source, findings: findings, to: destination)

        #expect(outcome.url == destination)
        #expect(outcome.pageCount == 5)
        #expect(outcome.dpi == 300)
        #expect(outcome.pagePixelSizes == [
            CGSize(width: 2550, height: 3300), // A4 portrait
            CGSize(width: 3300, height: 2550), // /Rotate 90 -> landscape
            CGSize(width: 3508, height: 2479), // landscape mediaBox
            CGSize(width: 1717, height: 2467), // cropBox 412x592
            CGSize(width: 2550, height: 3300), // /Rotate 180
        ])
        #expect(outcome.fileSizeBytes > 0)
        let destinationHash = try SHA256Hex.of(fileAt: destination)
        #expect(outcome.sha256 == destinationHash)

        let sourceBytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        print("[PaperVeilExportTests] Quelle: \(sourceBytes) Bytes, Export: \(outcome.fileSizeBytes) Bytes (5 Seiten, 300 dpi, verlustfrei)")

        let report = ExportValidator.validate(export: destination, original: source, findings: findings)
        #expect(report.passed, "Validator meldet: \(report.messages)")
        #expect(report.pageMeanAbsoluteDifferences.count == 5)

        // C02: original untouched by export and validation.
        #expect(try SHA256Hex.of(fileAt: source) == sourceHash)

        // No text layer, no annotations, neutral metadata.
        let document = try #require(PDFDocument(url: destination))
        #expect((document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        for index in 0..<document.pageCount {
            #expect(document.page(at: index)?.annotations.isEmpty == true)
        }
        let allowedInfoKeys: Set<String> = ["Creator", "Producer", "CreationDate", "ModDate", "Version"]
        for case let key as String in document.documentAttributes?.keys ?? [:].keys {
            #expect(allowedInfoKeys.contains(key), "Unerwarteter Metadatenschlüssel: \(key)")
        }
        for forbidden in ["Title", "Author", "Subject", "Keywords"] {
            #expect(document.documentAttributes?[AnyHashable(forbidden)] == nil, "\(forbidden) darf nicht gesetzt sein")
        }
    }

    /// Page count, order, orientation (and crop) survive the raster export.
    @Test func orientationAndCropPreserved() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let destination = dir.appendingPathComponent("PV-TESTFIX-r1.pdf")
        try TestFixtures.buildSource(source)
        let findings = TestFixtures.markerFindings()

        _ = try RasterExporter.export(original: source, findings: findings, to: destination, dpi: 120)

        let exportPDF = try #require(CGPDFDocument(destination as CFURL))
        let sourcePDF = try #require(CGPDFDocument(source as CFURL))
        #expect(exportPDF.numberOfPages == sourcePDF.numberOfPages)

        let expectedDisplayedSizes: [CGSize] = [
            CGSize(width: 612, height: 792),
            CGSize(width: 792, height: 612), // rotated
            CGSize(width: 842, height: 595),
            CGSize(width: 412, height: 592), // cropBox
            CGSize(width: 612, height: 792),
        ]
        for index in 1...5 {
            let exportPage = try #require(exportPDF.page(at: index))
            let sourcePage = try #require(sourcePDF.page(at: index))
            let exportGeometry = try #require(PageGeometry.displayed(exportPage))
            let sourceGeometry = try #require(PageGeometry.displayed(sourcePage))
            #expect(exportGeometry.displayedSize == sourceGeometry.displayedSize)
            #expect(exportGeometry.displayedSize == expectedDisplayedSizes[index - 1])
            // Rotation is baked into the pixels; the export needs no /Rotate.
            #expect(exportPage.rotationAngle == 0)
        }

        let kitDocument = try #require(PDFDocument(url: destination))
        let rotated = try #require(kitDocument.page(at: 1)).bounds(for: .mediaBox)
        #expect(rotated.width > rotated.height, "/Rotate-90-Seite muss im Export quer sein")
        let portrait = try #require(kitDocument.page(at: 0)).bounds(for: .mediaBox)
        #expect(portrait.width < portrait.height)

        let report = ExportValidator.validate(export: destination, original: source, findings: findings, dpi: 120)
        #expect(report.passed, "Validator meldet: \(report.messages)")
    }

    /// The export must refuse to write over the original, by direct path or
    /// by a lexically equivalent alias.
    @Test func refusesDestinationEqualToOriginal() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        try TestFixtures.buildSource(source)
        let sourceHash = try SHA256Hex.of(fileAt: source)

        #expect(throws: ExportError.destinationEqualsOriginal) {
            try RasterExporter.export(original: source, findings: [], to: source)
        }
        let aliased = source.deletingLastPathComponent()
            .appendingPathComponent("sub/../\(source.lastPathComponent)")
        #expect(throws: ExportError.destinationEqualsOriginal) {
            try RasterExporter.export(original: source, findings: [], to: aliased)
        }
        #expect(try SHA256Hex.of(fileAt: source) == sourceHash)
    }

    /// Findings outside the page range abort the export before anything is
    /// written, leaving no partial files behind.
    @Test func rejectsFindingsOutsidePageRange() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let destination = dir.appendingPathComponent("PV-TESTFIX-r1.pdf")
        try TestFixtures.buildSource(source)
        let bad = Finding(
            documentID: DocumentID(rawValue: "PV-TESTFIX"),
            pageIndex: 5,
            rects: [PageRect(x: 0, y: 0, width: 10, height: 10)],
            text: "", category: .other, origin: .manual
        )
        #expect(throws: ExportError.findingOutsidePageRange(5)) {
            try RasterExporter.export(original: source, findings: [bad], to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".pv-export-") }
        #expect(leftovers.isEmpty)
    }
}
