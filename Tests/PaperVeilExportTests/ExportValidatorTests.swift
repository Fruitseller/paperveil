import Foundation
import Testing
import PaperVeilCore
@testable import PaperVeilExport

@Suite struct ExportValidatorTests {
    /// The naive approach — copy the source and draw black square annotations
    /// over the secrets — must fail validation: the text is still extractable,
    /// annotations and metadata survive, and the pixels under the squares are
    /// not black.
    @Test func naiveBlackOverlayFailsValidation() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let naive = dir.appendingPathComponent("naiv.pdf")
        try TestFixtures.buildSource(source)
        try TestFixtures.buildSource(naive, naive: true)
        let sourceHash = try SHA256Hex.of(fileAt: source)
        let findings = TestFixtures.markerFindings()

        let report = ExportValidator.validate(export: naive, original: source, findings: findings, dpi: 120)

        #expect(!report.passed, "Die naive Schwärzung darf die Validierung nicht bestehen.")
        // C03: text still extractable under the overlay.
        #expect(report.messages.contains { $0.contains("Textebene") })
        // C04: annotations, forms and attachments survive in the naive copy.
        #expect(report.messages.contains { $0.contains("Annotation") })
        #expect(report.messages.contains { $0.contains("Metadaten") })
        #expect(report.messages.contains { $0.contains("Katalog") })
        // Pixel check: the marker region is not actually black.
        #expect(report.messages.contains { $0.contains("schwarz") })
        #expect(try SHA256Hex.of(fileAt: source) == sourceHash)
    }

    /// The real export passes; findings pointing at nonexistent pages make
    /// it fail with an explicit message.
    @Test func validatorRejectsFindingsOutsidePageRange() throws {
        let dir = TestFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("quelle.pdf")
        let destination = dir.appendingPathComponent("PV-TESTFIX-r1.pdf")
        try TestFixtures.buildSource(source)
        let findings = TestFixtures.markerFindings()
        _ = try RasterExporter.export(original: source, findings: findings, to: destination, dpi: 120)

        let good = ExportValidator.validate(export: destination, original: source, findings: findings, dpi: 120)
        #expect(good.passed, "Validator meldet: \(good.messages)")

        var withBogus = findings
        withBogus.append(Finding(
            documentID: DocumentID(rawValue: "PV-TESTFIX"),
            pageIndex: 9,
            rects: [PageRect(x: 10, y: 10, width: 10, height: 10)],
            text: "", category: .other, origin: .manual
        ))
        let bad = ExportValidator.validate(export: destination, original: source, findings: withBogus, dpi: 120)
        #expect(!bad.passed)
        #expect(bad.messages.contains { $0.contains("nicht vorhandene Seite 10") })
    }

    /// Validation of a nonexistent export reports failure, not a crash.
    @Test func missingExportFailsCleanly() {
        let dir = TestFixtures.tempDir()
        let missing = dir.appendingPathComponent("gibtsnicht.pdf")
        let report = ExportValidator.validate(export: missing, original: missing, findings: [])
        #expect(!report.passed)
        #expect(!report.messages.isEmpty)
    }
}
