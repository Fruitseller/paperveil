import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PaperVeilCore

/// A word drawn at a known position plus the rectangle it occupies in PDF
/// page space (unrotated media box space, points).
struct DrawnWord {
    let text: String
    let expectedRect: CGRect
}

/// Builds synthetic, purely fictional PDFs with CoreGraphics/CoreText.
/// All sample content is fictional German-language data (no real persons).
struct PDFFixtureFactory {
    let directory: URL
    let mediaBox: CGRect
    let font: CTFont

    /// US-Letter portrait page, 24 pt Helvetica (CoreGraphics substitutes an
    /// available sans-serif if Helvetica is unavailable on the machine).
    init(directory: URL,
         mediaBox: CGRect = CGRect(x: 0, y: 0, width: 612, height: 792),
         fontName: String = "Helvetica",
         fontSize: CGFloat = 24) throws {
        self.directory = directory
        self.mediaBox = mediaBox
        self.font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Text PDFs

    /// PDF with selectable text drawn at known positions.
    /// Returns per-word expectations for geometry assertions.
    mutating func makeTextPDF(named name: String, lines: [(text: String, at: CGPoint)]) throws -> (url: URL, words: [DrawnWord]) {
        let url = directory.appendingPathComponent(name)
        var box = mediaBox
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "fixtures", code: 1)
        }
        context.beginPDFPage(nil)
        var words: [DrawnWord] = []
        for line in lines {
            words.append(contentsOf: drawText(line.text, at: line.at, in: context))
        }
        context.endPDFPage()
        context.closePDF()
        return (url, words)
    }

    // MARK: - Scan PDFs

    /// Image-only "scan" page: German text rendered into a 300 dpi bitmap that
    /// covers the whole page. Returns page-space word expectations.
    /// `lines` are (text, origin) pairs in bitmap coordinates.
    func makeScanPDF(named name: String,
                     lines: [(text: String, origin: CGPoint)],
                     bitmapSize: CGSize = CGSize(width: 2550, height: 3300),
                     fontSize: CGFloat = 96) throws -> (url: URL, words: [DrawnWord]) {
        let (image, bitmapWords) = scanBitmap(lines: lines, bitmapSize: bitmapSize, fontSize: fontSize)
        let url = directory.appendingPathComponent(name)
        var box = mediaBox
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(origin: .zero, size: mediaBox.size))
        context.endPDFPage()
        context.closePDF()
        return (url, scaledToPageSpace(bitmapWords, bitmapSize: bitmapSize))
    }

    /// Mixed page: real PDF text plus a large scan image on the same page.
    mutating func makeMixedPDF(named name: String,
                               pdfText: String,
                               pdfTextOrigin: CGPoint,
                               scanText: String,
                               scanDrawOrigin: CGPoint = CGPoint(x: 300, y: 1250)) throws -> (url: URL, words: [DrawnWord]) {
        let (image, bitmapWords) = scanBitmap(lines: [(scanText, scanDrawOrigin)],
                                              bitmapSize: CGSize(width: 2550, height: 3300))
        let url = directory.appendingPathComponent(name)
        var box = mediaBox
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "fixtures", code: 2)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(origin: .zero, size: mediaBox.size))
        let textWords = drawText(pdfText, at: pdfTextOrigin, in: context)
        context.endPDFPage()
        context.closePDF()
        var words = textWords
        words.append(contentsOf: scaledToPageSpace(bitmapWords, bitmapSize: CGSize(width: 2550, height: 3300)))
        return (url, words)
    }

    /// Renders text lines into a white 300 dpi bitmap and computes the drawn
    /// word rectangles in *bitmap* coordinates.
    private func scanBitmap(lines: [(text: String, origin: CGPoint)],
                            bitmapSize: CGSize,
                            fontSize: CGFloat = 96) -> (image: CGImage, words: [DrawnWord]) {
        let context = CGContext(
            data: nil, width: Int(bitmapSize.width), height: Int(bitmapSize.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: bitmapSize))

        let scanFont = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr: [NSAttributedString.Key: Any] = [
            .font: scanFont,
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        var words: [DrawnWord] = []
        for line in lines {
            let attributed = CFAttributedStringCreate(nil, line.text as CFString, attr as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = line.origin
            CTLineDraw(ctLine, context)
            words.append(contentsOf: wordExpectations(for: line.text, line: ctLine, origin: line.origin,
                                                      ascent: CTFontGetAscent(scanFont),
                                                      descent: CTFontGetDescent(scanFont)))
        }
        return (context.makeImage()!, words)
    }

    // MARK: - Variants of existing PDFs

    /// Reloads a PDF, sets /Rotate on its first page and stores it again
    /// (PDFPage.rotation + write, as the task prescribes).
    func rotatedCopy(of url: URL, rotation: Int, named name: String) throws -> URL {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(domain: "fixtures", code: 3)
        }
        page.rotation = rotation
        let target = directory.appendingPathComponent(name)
        document.write(to: target)
        return target
    }

    /// Reloads a PDF, offsets its crop box and stores it again.
    func croppedCopy(of url: URL, cropBox: CGRect, named name: String) throws -> URL {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw NSError(domain: "fixtures", code: 4)
        }
        page.setBounds(cropBox, for: .cropBox)
        let target = directory.appendingPathComponent(name)
        document.write(to: target)
        return target
    }

    /// Encrypted copy. CoreGraphics only enables encryption when an owner
    /// password is present as well (a lone user password is ignored), so both
    /// are set — opening the copy then requires the user password.
    func encryptedCopy(of url: URL, userPassword: String, ownerPassword: String, named name: String) throws -> URL {
        guard let document = PDFDocument(url: url) else {
            throw NSError(domain: "fixtures", code: 5)
        }
        let target = directory.appendingPathComponent(name)
        document.write(to: target, withOptions: [
            PDFDocumentWriteOption.ownerPasswordOption: ownerPassword,
            PDFDocumentWriteOption.userPasswordOption: userPassword,
        ])
        return target
    }

    /// Structurally valid PDF without any page (valid xref, `%%EOF`, no /Type /Page).
    func zeroPagePDF(named name: String) throws -> URL {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        let url = directory.appendingPathComponent(name)
        try pdf.data(using: .isoLatin1)!.write(to: url)
        return url
    }

    /// First half of an existing PDF's bytes — incomplete file.
    func truncatedCopy(of url: URL, named name: String) throws -> URL {
        let data = try Data(contentsOf: url)
        let target = directory.appendingPathComponent(name)
        try data.prefix(data.count / 2).write(to: target)
        return target
    }

    /// A plain text file with a `.pdf` extension.
    func textFileRenamedAsPDF(named name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Geometry helpers

    /// Draws one text line and returns the expected word rects (PDF page space).
    private func drawText(_ text: String, at origin: CGPoint, in context: CGContext) -> [DrawnWord] {
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attr as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = origin
        CTLineDraw(line, context)
        return wordExpectations(for: text, line: line, origin: origin,
                                ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font))
    }

    /// Splits `text` into whitespace-separated words and computes each word's
    /// typographic rectangle relative to `origin` using the line's glyph offsets.
    private func wordExpectations(for text: String, line: CTLine, origin: CGPoint,
                                  ascent: CGFloat, descent: CGFloat) -> [DrawnWord] {
        let nsText = text as NSString
        var result: [DrawnWord] = []
        var scanner = 0
        while scanner < nsText.length {
            while scanner < nsText.length, isSeparator(nsText.character(at: scanner)) { scanner += 1 }
            let start = scanner
            while scanner < nsText.length, !isSeparator(nsText.character(at: scanner)) { scanner += 1 }
            guard scanner > start else { continue }
            let range = NSRange(location: start, length: scanner - start)
            let x0 = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            result.append(DrawnWord(
                text: nsText.substring(with: range),
                expectedRect: CGRect(x: origin.x + x0, y: origin.y - descent,
                                    width: x1 - x0, height: ascent + descent)
            ))
        }
        return result
    }

    /// Bitmap words → page space (image fills the whole page).
    private func scaledToPageSpace(_ words: [DrawnWord], bitmapSize: CGSize) -> [DrawnWord] {
        let sx = mediaBox.width / bitmapSize.width
        let sy = mediaBox.height / bitmapSize.height
        return words.map { word in
            DrawnWord(text: word.text,
                      expectedRect: CGRect(x: word.expectedRect.minX * sx,
                                           y: word.expectedRect.minY * sy,
                                           width: word.expectedRect.width * sx,
                                           height: word.expectedRect.height * sy))
        }
    }

    private func isSeparator(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }
}

// MARK: - Small async helpers for cancellation tests

/// One-shot gate: an async task parks in `wait()` until `signal()` is called.
/// Not cancellation-aware on purpose: the parked task continues and must then
/// observe cancellation itself.
final class Gate: @unchecked Sendable {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        isSignaled = true
        continuation?.resume()
        continuation = nil
        lock.unlock()
    }
}

/// Fraction of `inner`'s area that lies inside `outer` (0 … 1).
func overlapFraction(of inner: CGRect, with outer: CGRect) -> CGFloat {
    let intersection = inner.intersection(outer)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }
    return (intersection.width * intersection.height) / (inner.width * inner.height)
}

/// Each test creates its own factory with a unique temp directory (tests run
/// in parallel).
func makeFixtureFactory() throws -> PDFFixtureFactory {
    try PDFFixtureFactory(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("paperveil-extraction-tests-\(UUID().uuidString)", isDirectory: true)
    )
}
