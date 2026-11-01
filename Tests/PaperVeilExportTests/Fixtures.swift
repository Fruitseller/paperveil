import Foundation
import PaperVeilCore

/// Minimal raw-PDF writer for synthetic, purely fictional test documents.
/// Written by hand (not PDFKit) so that every side channel — invisible text,
/// info dictionary, annotations, form widgets, embedded files — is under
/// exact control.
final class TestPDFBuilder {
    private var objects: [(body: String, stream: Data?)] = []

    /// Adds a plain object; returns its object number.
    @discardableResult
    func add(_ body: String) -> Int {
        objects.append((body, nil))
        return objects.count
    }

    /// Adds a stream object; `{L}` in `dict` is replaced with the stream length.
    @discardableResult
    func addStream(_ dict: String, data: Data) -> Int {
        objects.append((dict.replacingOccurrences(of: "{L}", with: String(data.count)), data))
        return objects.count
    }

    func write(to url: URL, root: Int, info: Int?) throws {
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.count)
            out += Data("\(index + 1) 0 obj\n".utf8)
            if let stream = object.stream {
                out += Data("\(object.body)\nstream\n".utf8)
                out += stream
                out += Data("\nendstream\n".utf8)
            } else {
                out += Data(object.body.utf8)
                out += Data("\n".utf8)
            }
            out += Data("endobj\n".utf8)
        }
        let xrefOffset = out.count
        out += Data("xref\n0 \(objects.count + 1)\n".utf8)
        out += Data("0000000000 65535 f \n".utf8)
        for offset in offsets {
            out += Data(String(format: "%010d 00000 n \n", offset).utf8)
        }
        out += Data("trailer\n<< /Size \(objects.count + 1) /Root \(root) 0 R".utf8)
        if let info { out += Data(" /Info \(info) 0 R".utf8) }
        out += Data(" >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        try out.write(to: url)
    }
}

/// The fictional acceptance fixture for the export module.
///
/// Page 1 (portrait): visible marker "GEHEIM-4711" (to be redacted), the same
/// marker as invisible text (`3 Tr`), as white-on-white text, a text note
/// annotation, a free-text annotation, a form widget field, the marker in the
/// info dictionary, an embedded file attachment, and a non-redacted medical
/// line "Kalium 4,2 mmol/l" that must survive.
/// Page 2: portrait content with /Rotate 90 (displays landscape).
/// Page 3: landscape mediaBox.
/// Page 4: cropBox with non-zero origin.
/// Page 5: /Rotate 180.
///
/// `naive: true` builds the "naive approach" variant: a copy of the source
/// with black square annotations over the markers — but with the text layer,
/// metadata, forms and attachments still intact.
enum TestFixtures {
    static let marker = "GEHEIM-4711"

    /// User-space rects (unrotated mediaBox space) around the visible marker
    /// on each page, in page order.
    static let markerRects: [CGRect] = [
        CGRect(x: 70, y: 694, width: 104, height: 22),
        CGRect(x: 70, y: 694, width: 104, height: 22),
        CGRect(x: 70, y: 514, width: 104, height: 22),
        CGRect(x: 148, y: 594, width: 104, height: 22),
        CGRect(x: 70, y: 694, width: 104, height: 22),
    ]

    /// One accepted finding per page over the visible marker.
    static func markerFindings() -> [Finding] {
        markerRects.enumerated().map { index, rect in
            Finding(
                documentID: DocumentID(rawValue: "PV-TESTFIX"),
                pageIndex: index,
                rects: [PageRect(rect)],
                text: marker,
                category: .patientID,
                origin: .manual,
                decision: .accepted
            )
        }
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperVeilExportTests-\(UUID().uuidString)", isDirectory: true)
    }

    static func buildSource(_ url: URL, naive: Bool = false) throws {
        let b = TestPDFBuilder()
        // 1 catalog, 2 pages tree
        b.add("<< /Type /Catalog /Pages 2 0 R /AcroForm 10 0 R /Names << /EmbeddedFiles 11 0 R >> >>")
        b.add("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R] /Count 5 >>")
        // 3–7 page dicts
        for pageIndex in 0..<5 {
            var dict = "<< /Type /Page /Parent 2 0 R "
            switch pageIndex {
            case 0: dict += "/MediaBox [0 0 612 792] "
            case 1: dict += "/MediaBox [0 0 612 792] /Rotate 90 "
            case 2: dict += "/MediaBox [0 0 842 595] "
            case 3: dict += "/MediaBox [0 0 612 792] /CropBox [100 100 512 692] "
            case 4: dict += "/MediaBox [0 0 612 792] /Rotate 180 "
            default: break
            }
            dict += "/Resources << /Font << /F1 8 0 R /F2 9 0 R >> >> /Contents \(18 + pageIndex) 0 R"
            if pageIndex == 0 {
                dict += " /Annots [12 0 R 13 0 R 14 0 R"
                if naive { dict += " 23 0 R" }
                dict += "]"
            } else if naive {
                dict += " /Annots [\(23 + pageIndex) 0 R]"
            }
            dict += " >>"
            b.add(dict)
        }
        // 8–9 fonts, 10 acro form, 11 embedded files name tree
        b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>")
        b.add("<< /Fields [14 0 R] /DA (/F1 12 Tf 0 g) >>")
        b.add("<< /Names [(geheim.txt) 15 0 R] >>")
        // 12–14 annotations on page 1 (note, free text, form widget)
        b.add("<< /Type /Annot /Subtype /Text /Rect [500 700 530 730] /Contents (Notiz: \(marker)) /F 4 >>")
        b.add("<< /Type /Annot /Subtype /FreeText /Rect [300 300 500 330] /Contents (Freitext: \(marker)) /DA (/F1 12 Tf 0 g) /F 4 >>")
        b.add("<< /Type /Annot /Subtype /Widget /FT /Tx /T (PatientenNr) /V (\(marker)) /Rect [400 100 500 130] /F 4 /P 3 0 R >>")
        // 15–16 embedded file attachment
        b.add("<< /Type /Filespec /F (geheim.txt) /EF << /F 16 0 R >> >>")
        b.addStream("<< /Type /EmbeddedFile /Length {L} >>", data: Data("\(marker) im Anhang\n".utf8))
        // 17 info dictionary with the marker
        b.add("<< /Title (Befund \(marker)) /Author (Max Muster) /Subject (Fiktiver Testbefund \(marker)) /Keywords (\(marker), fiktiv) /Creator (Fiktiv-App) /Producer (Fiktiv-Generator) >>")
        // 18–22 page content
        for pageIndex in 0..<5 {
            b.addStream("<< /Length {L} >>", data: Data(content(page: pageIndex).utf8))
        }
        // 23–27 naive black overlay squares over the markers
        if naive {
            for rect in markerRects {
                let square = rect.insetBy(dx: -2, dy: -2)
                b.add("<< /Type /Annot /Subtype /Square /Rect [\(format(square.minX)) \(format(square.minY)) \(format(square.maxX)) \(format(square.maxY))] /C [0 0 0] /IC [0 0 0] /F 4 >>")
            }
        }
        try b.write(to: url, root: 1, info: 17)
    }

    /// Page content: the visible marker sits at the marker rect's lower-left
    /// corner (baseline), the medical line 80 pt below it.
    private static func content(page: Int) -> String {
        let rect = markerRects[page]
        let x = format(rect.minX + 2)
        let baseline = format(rect.minY + 6)
        let medicalX = format(rect.minX + 2)
        let medicalY = format(rect.minY - 74)
        var lines = [
            "BT /F2 14 Tf 1 0 0 1 \(x) \(baseline) Tm (\(marker)) Tj ET",
        ]
        if page == 0 {
            // Same marker, invisible to the eye but extractable.
            lines.append("BT /F2 14 Tf 3 Tr 1 0 0 1 \(x) \(format(rect.minY - 18)) Tm (\(marker)) Tj ET")
            lines.append("BT /F2 14 Tf 0 Tr 1 1 1 rg 1 0 0 1 \(x) \(format(rect.minY - 42)) Tm (\(marker)) Tj ET")
        }
        lines.append("BT /F1 14 Tf 0 0 0 rg 1 0 0 1 \(medicalX) \(medicalY) Tm (Kalium 4,2 mmol/l \\(Referenz 3,5-5,1 mmol/l\\)) Tj ET")
        if page == 0 {
            lines.append("BT /F1 14 Tf 1 0 0 1 \(medicalX) \(format(rect.minY - 98)) Tm (Natrium 139 mmol/l) Tj ET")
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
