import CoreGraphics
import Foundation
import PaperVeilCore

/// A4 page in points.
let kA4 = CGSize(width: 595.28, height: 841.89)

/// CFData value for kCGPDFContextMediaBox / kCGPDFContextCropBox (CGRect by value).
func pdfBoxValue(_ r: CGRect) -> CFData {
    withUnsafeBytes(of: r) { raw in
        CFDataCreate(nil, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)!
    }
}

/// Page-space result of one drawn text line, with page index attached.
struct PlacedLine {
    let pageIndex: Int
    let drawn: DrawnLine

    var rect: CGRect { drawn.rect }

    func rect(of substring: String, occurrence: Int = 0) -> CGRect {
        drawn.rect(of: substring, occurrence: occurrence)
    }
}

/// Wraps a CGPDFContext and draws pages with the synthetic footer.
final class PDFDoc {
    let ctx: CGContext
    private(set) var pageIndex = -1
    private(set) var pageCount = 0
    var pageBounds: CGRect = CGRect(origin: .zero, size: kA4)

    init(url: URL, defaultMediaBox: CGRect,
         metadata: [CFString: Any] = [:]) throws {
        var mb = defaultMediaBox
        var aux: [CFString: Any] = [
            kCGPDFContextCreator: "pv-fixtures",
            kCGPDFContextAuthor: "Musterklinik Beispielstadt",
        ]
        metadata.forEach { aux[$0.key] = $0.value }
        guard let c = CGContext(url as CFURL, mediaBox: &mb, aux as CFDictionary) else {
            throw FixtureError.pdfContextFailed(url.path)
        }
        ctx = c
    }

    /// Begins a page. `crop` may be smaller than the media box (crop box
    /// content is still present in the content stream).
    func beginPage(media: CGRect? = nil, crop: CGRect? = nil) {
        var info: [CFString: Any] = [:]
        let m = media ?? CGRect(origin: .zero, size: kA4)
        info[kCGPDFContextMediaBox] = pdfBoxValue(m)
        if let crop { info[kCGPDFContextCropBox] = pdfBoxValue(crop) }
        ctx.beginPDFPage(info as CFDictionary)
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.butt)
        pageBounds = m
        pageIndex += 1
        pageCount += 1
    }

    func endPage() {
        ctx.endPDFPage()
    }

    func close() {
        ctx.closePDF()
    }

    // MARK: drawing helpers (all in unrotated page space, points)

    @discardableResult
    func draw(_ text: String, font: FontSpec, at baseline: CGPoint,
              color: CGColor = kFontBlack) -> PlacedLine {
        PlacedLine(pageIndex: pageIndex,
                   drawn: TextRender.draw(ctx, text, font: font, at: baseline, color: color))
    }

    @discardableResult
    func drawParagraph(_ text: String, font: FontSpec, at origin: CGPoint, maxWidth: CGFloat,
                      leading: CGFloat, color: CGColor = kFontBlack) -> [PlacedLine] {
        TextRender.drawParagraph(ctx, text, font: font, at: origin, maxWidth: maxWidth,
                                 leading: leading, color: color)
            .map { PlacedLine(pageIndex: pageIndex, drawn: $0) }
    }

    /// Horizontal rule.
    func rule(from a: CGPoint, to b: CGPoint, width: CGFloat = 0.8, color: CGColor = kFontGray) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    /// Synthetic footer, bottom center of every page.
    @discardableResult
    func drawFooter() -> PlacedLine {
        drawFooter(atY: 16)
    }

    /// Footer at a custom height (needed when the crop box starts above y=16).
    @discardableResult
    func drawFooter(atY y: CGFloat) -> PlacedLine {
        let w = TextRender.width(of: Fiction.footer, font: .helveticaOblique(7))
        return draw(Fiction.footer, font: .helveticaOblique(7),
                    at: CGPoint(x: pageBounds.midX - w / 2, y: y), color: kFontGray)
    }

    /// Invisible text (PDF text render mode 3): extractable, not rendered.
    @discardableResult
    func drawInvisible(_ text: String, font: FontSpec, at baseline: CGPoint) -> PlacedLine {
        ctx.setTextDrawingMode(.invisible)
        let result = draw(text, font: font, at: baseline)
        ctx.setTextDrawingMode(.fill)
        return result
    }

    /// White-on-white text: extractable, visually hidden against white paper.
    @discardableResult
    func drawWhiteOnWhite(_ text: String, font: FontSpec, at baseline: CGPoint) -> PlacedLine {
        draw(text, font: font, at: baseline, color: kFontWhite)
    }
}

// MARK: - Errors

enum FixtureError: Error, CustomStringConvertible {
    case pdfContextFailed(String)
    case writeFailed(String)
    case verificationFailed([String])

    var description: String {
        switch self {
        case .pdfContextFailed(let p): return "PDF-Kontext konnte nicht erstellt werden: \(p)"
        case .writeFailed(let p): return "Datei konnte nicht geschrieben werden: \(p)"
        case .verificationFailed(let errors):
            return "Selbstprüfung fehlgeschlagen:\n" + errors.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}
