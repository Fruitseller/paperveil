import Foundation
import PDFKit
import Testing
import PaperVeilCore
@testable import PaperVeilExtraction

@Suite("InputValidator")
struct InputValidatorTests {

    // MARK: Errors

    @Test("Textdatei mit .pdf-Endung ist kein PDF")
    func rejectsTextFileRenamedAsPDF() throws {
        let factory = try makeFixtureFactory()
        let url = try factory.textFileRenamedAsPDF(
            named: "kein-pdf.pdf",
            contents: "Dies ist nur eine Textdatei.\nZweite Zeile ohne PDF-Inhalt."
        )
        #expect(throws: InputError.notAPDF) {
            try InputValidator.validate(url: url)
        }
    }

    @Test("Abgeschnittene PDF-Bytes sind beschädigt")
    func rejectsTruncatedPDF() throws {
        var factory = try makeFixtureFactory()
        let (textURL, _) = try factory.makeTextPDF(
            named: "ganz.pdf",
            lines: [("Geburtsdatum 12.03.1961", CGPoint(x: 100, y: 700))]
        )
        let truncated = try factory.truncatedCopy(of: textURL, named: "abgeschnitten.pdf")
        #expect(throws: InputError.damagedOrUnparseable) {
            try InputValidator.validate(url: truncated)
        }
    }

    @Test("PDF ohne Seiten")
    func rejectsZeroPagePDF() throws {
        let factory = try makeFixtureFactory()
        let url = try factory.zeroPagePDF(named: "leer.pdf")
        #expect(throws: InputError.zeroPages) {
            try InputValidator.validate(url: url)
        }
    }

    @Test("Struktur mit %%EOF, aber ohne Seitenbaum ist beschädigt, nicht leer")
    func rejectsBrokenPDFWithEOF() throws {
        let factory = try makeFixtureFactory()
        // Gültige Struktur mit %%EOF am Ende, aber der Katalog zeigt auf ein
        // fehlendes Pages-Objekt — kein Hinweis auf einen leeren Seitenbaum.
        let pdf = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        xref
        0 2
        0000000000 65535 f 
        trailer
        << /Size 2 /Root 1 0 R >>
        startxref
        10
        %%EOF
        """
        let url = factory.directory.appendingPathComponent("kaputt.pdf")
        try pdf.data(using: .isoLatin1)!.write(to: url)
        #expect(throws: InputError.damagedOrUnparseable) {
            try InputValidator.validate(url: url)
        }
    }

    @Test("Passwortgeschütztes PDF wird abgelehnt, ohne Entsperrversuch")
    func rejectsEncryptedPDF() throws {
        var factory = try makeFixtureFactory()
        let (textURL, _) = try factory.makeTextPDF(
            named: "klartext.pdf",
            lines: [("Befund Patient", CGPoint(x: 72, y: 700))]
        )
        // CoreGraphics verschlüsselt erst mit Owner-Passwort; das User-Passwort
        // wird zusätzlich gesetzt, sodass Öffnen ohne Passwort scheitert.
        let encrypted = try factory.encryptedCopy(of: textURL, userPassword: "geheim",
                                                  ownerPassword: "besitzer", named: "verschlüsselt.pdf")
        #expect(throws: InputError.encryptedOrLocked) {
            try InputValidator.validate(url: encrypted)
        }
    }

    @Test("Unlesbare / fehlende Datei")
    func rejectsUnreadableFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("existiert-nicht-\(UUID().uuidString).pdf")
        #expect(throws: InputError.unreadableFile) {
            try InputValidator.validate(url: missing)
        }
    }

    // MARK: Success

    @Test("Gültiges PDF wird akzeptiert")
    func acceptsValidPDF() throws {
        var factory = try makeFixtureFactory()
        let (url, _) = try factory.makeTextPDF(
            named: "gültig.pdf",
            lines: [("Laborwert 42,5 mg/dl", CGPoint(x: 72, y: 700))]
        )
        let validated = try InputValidator.validate(url: url)
        #expect(validated.pageCount == 1)
        #expect(validated.url == url)
        #expect(validated.document.pageCount == 1)

        // Fehlermeldungen sind deutschsprachig und verständlich.
        for error in [InputError.unreadableFile, .notAPDF, .damagedOrUnparseable, .zeroPages, .encryptedOrLocked] {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("Validierung verändert die Originaldatei nicht")
    func validationDoesNotModifyInput() throws {
        var factory = try makeFixtureFactory()
        let (url, _) = try factory.makeTextPDF(
            named: "original.pdf",
            lines: [("Hash bleibt gleich", CGPoint(x: 72, y: 700))]
        )
        let before = try SHA256Hex.of(fileAt: url)
        _ = try InputValidator.validate(url: url)
        let after = try SHA256Hex.of(fileAt: url)
        #expect(before == after)
    }
}
