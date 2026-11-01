import AppKit
import Compression
import PDFKit
import Foundation
import PaperVeilCore

// MARK: - Check descriptions produced by the builders

enum VerifyItem {
    case pageCount(Int)
    /// /Rotate per page, via CGPDFDocument (object level).
    case rotations([Int])
    /// Crop box of one page, via CGPDFDocument.
    case cropBox(page: Int, rect: CGRect)
    /// Page text contains `needle` (whitespace-normalized, occurrence-based).
    /// If `rects` is non-empty, every rect must intersect the PDFKit selection
    /// bounds of that match. For multi-line needles each line is checked
    /// against its rect. Empty rects mean a string-presence-only check.
    case pageText(page: Int, needle: String, occurrence: Int, rects: [CGRect], note: String)
    /// Medical string must survive in the extracted page text.
    case mustPreserveText(page: Int, needle: String)
    /// A scan page has no text layer (page.string empty or nil).
    case noTextLayer(page: Int)
    /// The given rect contains dark pixels when the page is rendered. The
    /// threshold adapts to degraded scans (blurred text is gray, not black).
    case darkPixels(page: Int, rect: CGRect, label: String, threshold: Int = 140)
    /// The (possibly Flate-compressed) content stream of the page contains the
    /// needle (for identifiers invisible to PDFKit extraction, e.g. outside
    /// the crop box).
    case contentStream(page: Int, needle: String)
    /// The needle must NOT appear in the PDFKit-extracted page text (negative
    /// control, e.g. text outside the crop box).
    case absentFromPageText(page: Int, needle: String)
    /// Document info metadata contains a string.
    case metadata(key: String, contains: String)
    /// An AcroForm text field whose value contains the given string.
    case formField(page: Int, contains: String)
    /// A text (sticky note) annotation with given contents.
    case stickyNote(page: Int, contains: String)
    /// Catalog has /Names /EmbeddedFiles with the given file and payload.
    case attachment(file: String, contentContains: String)
    /// Encrypted document unlocks with the password.
    case unlock(password: String)
    /// Damaged input: must not open cleanly with the original page count.
    case damaged(originalPageCount: Int, originalBytes: Int)
    /// The raw file bytes must not contain the given (real-person) string.
    case privacyScan(string: String, label: String)
}

// MARK: - Normalized whitespace matching

/// Collapses every whitespace run to a single space while remembering the raw
/// (UTF-16) source range of each normalized character, so matches in the
/// normalized text can be mapped back to raw NSRange values for PDFKit.
struct NormalizedText {
    let normalized: [unichar]
    let starts: [Int]   // raw UTF-16 start of each normalized character (or of a collapsed run)
    let ends: [Int]     // raw UTF-16 end of each normalized character (or run)

    private static func isWS(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
    }

    init(_ raw: String) {
        let ns = raw as NSString
        var norm: [unichar] = []
        var st: [Int] = []
        var en: [Int] = []
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if Self.isWS(c) {
                var j = i
                while j < ns.length, Self.isWS(ns.character(at: j)) { j += 1 }
                // Drop leading and trailing whitespace, keep inner runs as one space.
                if !norm.isEmpty, j < ns.length {
                    norm.append(0x20)
                    st.append(i)
                    en.append(j)
                }
                i = j
            } else {
                norm.append(c)
                st.append(i)
                en.append(i + 1)
                i += 1
            }
        }
        normalized = norm
        starts = st
        ends = en
    }

    /// Raw UTF-16 ranges of all whitespace-normalized matches of `needle`.
    func rawRanges(of needle: String) -> [NSRange] {
        let n = NormalizedText(needle).normalized
        guard !n.isEmpty, n.count <= normalized.count else { return [] }
        var result: [NSRange] = []
        var start = 0
        while start + n.count <= normalized.count {
            if Array(normalized[start..<(start + n.count)]) == n {
                let rawStart = starts[start]
                let rawEnd = ends[start + n.count - 1]
                result.append(NSRange(location: rawStart, length: rawEnd - rawStart))
                start += 1
            } else {
                start += 1
            }
        }
        return result
    }
}

// MARK: - Verifier

struct Verifier {
    var errors: [String] = []
    let file: String
    private var fileURL: URL?
    private var pdfDoc: PDFDocument?

    init(file: String) { self.file = file }

    mutating func run(url: URL, items: [VerifyItem], password: String?) {
        fileURL = url
        pdfDoc = PDFDocument(url: url)
        if let password {
            guard let doc = pdfDoc else {
                fail("verschlüsseltes PDF lässt sich nicht öffnen.")
                return
            }
            if !doc.unlock(withPassword: password) {
                fail("Entschlüsselung mit Benutzerpasswort fehlgeschlagen.")
                return
            }
        }
        for item in items { run(item) }
    }

    private mutating func fail(_ message: String) {
        errors.append("\(file): \(message)")
    }

    private mutating func note(_ message: String) {
        errors.append("\(file): wie erwartet – \(message)")
    }

    private mutating func run(_ item: VerifyItem) {
        switch item {
        case .pageCount(let expected):
            guard let doc = pdfDoc else {
                fail("PDFDocument kann Datei nicht öffnen.")
                return
            }
            if doc.pageCount != expected {
                fail("Seitenzahl \(doc.pageCount), erwartet \(expected).")
            }

        case .rotations(let expected):
            guard let url = fileURL, let cg = CGPDFDocument(url as CFURL) else {
                fail("CGPDFDocument kann Datei nicht öffnen (rotations-Prüfung).")
                return
            }
            for (i, deg) in expected.enumerated() {
                guard let page = cg.page(at: i + 1) else { continue }
                if page.rotationAngle != deg {
                    fail("Seite \(i): /Rotate \(page.rotationAngle), erwartet \(deg).")
                }
            }

        case .cropBox(let page, let rect):
            guard let url = fileURL, let cg = CGPDFDocument(url as CFURL),
                  let p = cg.page(at: page + 1) else {
                fail("CGPDFDocument kann Seite \(page) nicht öffnen (cropBox-Prüfung).")
                return
            }
            let crop = p.getBoxRect(.cropBox)
            if abs(crop.minX - rect.minX) > 0.5 || abs(crop.minY - rect.minY) > 0.5 ||
                abs(crop.width - rect.width) > 0.5 || abs(crop.height - rect.height) > 0.5 {
                fail("Seite \(page): CropBox \(crop), erwartet \(rect).")
            }

        case .pageText(let page, let needle, let occurrence, let rects, let note):
            checkPageText(page: page, needle: needle, occurrence: occurrence, rects: rects, note: note)

        case .mustPreserveText(let page, let needle):
            guard let s = pageString(page) else {
                fail("Seite \(page) nicht lesbar für Muss-Erhalt-Text „\(needle)“.")
                return
            }
            if NormalizedText(s).rawRanges(of: needle).isEmpty {
                fail("Seite \(page): Muss-Erhalt-Text nicht im Seiteninhalt gefunden: „\(needle)“.")
            }

        case .noTextLayer(let page):
            guard let s = pageString(page) else { return } // nil = no text layer at all
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fail("Seite \(page): Scan-Seite sollte keine Textebene haben, gefunden: \(s.prefix(80))…")
            }

        case .darkPixels(let page, let rect, let label, let threshold):
            if !hasDarkPixels(page: page, in: rect, threshold: threshold) {
                fail("Seite \(page): Bereich „\(label)“ \(rect) enthält keine ausreichend dunklen Pixel.")
            }

        case .contentStream(let page, let needle):
            guard let data = fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
                fail("contentStream: Datei nicht lesbar.")
                return
            }
            let found = data.range(of: Data(needle.utf8)) != nil
                || contentStreamContains(data: data, page: page, needle: needle)
            if !found {
                fail("Seite \(page): Content-Stream enthält „\(needle)“ nicht (erwartet: außerhalb der CropBox gezeichnet, aber im Content-Stream vorhanden).")
            }

        case .absentFromPageText(let page, let needle):
            guard let s = pageString(page) else { return }
            if !NormalizedText(s).rawRanges(of: needle).isEmpty {
                fail("Seite \(page): „\(needle)“ sollte von der PDFKit-Textextraktion NICHT geliefert werden (außerhalb der CropBox).")
            }

        case .metadata(let key, let contains):
            guard let doc = pdfDoc else { return }
            let rawValue = doc.documentAttributes?[key as NSString]
            let value: String
            if let v = rawValue as? String { value = v }
            else if let a = rawValue as? [String] { value = a.joined(separator: ", ") }
            else { value = "" }
            if !value.contains(contains) {
                fail("Metadatum \(key) enthält nicht „\(contains)“ (tatsächlich: „\(value)“).")
            }

        case .formField(let page, let contains):
            guard let doc = pdfDoc, let p = doc.page(at: page) else { return }
            let match = p.annotations.contains { a in
                (a.value(forAnnotationKey: .widgetValue) as? String ?? "").contains(contains)
            }
            if !match {
                fail("Seite \(page): Formularfeld mit Wert „\(contains)“ nicht gefunden.")
            }

        case .stickyNote(let page, let contains):
            guard let doc = pdfDoc, let p = doc.page(at: page) else { return }
            let found = p.annotations.contains { $0.type == "Text" && $0.contents?.contains(contains) == true }
            if !found {
                fail("Seite \(page): Text-Annotation mit Inhalt „\(contains)“ nicht gefunden.")
            }

        case .attachment(let file, let contentContains):
            guard let data = fileURL.flatMap({ try? Data(contentsOf: $0) }),
                  let raw = RawPDF.parse(data) else {
                fail("Anhangprüfung: Datei nicht parsebar.")
                return
            }
            let catalog = raw.body(of: raw.rootNumber)
            guard catalog.contains("/EmbeddedFiles") else {
                fail("Katalog enthält kein /Names /EmbeddedFiles.")
                return
            }
            if data.range(of: Data(file.utf8)) == nil {
                fail("Eingebetteter Dateiname \(file) fehlt in der Datei.")
            }
            if data.range(of: Data(contentContains.utf8)) == nil {
                fail("Anhanginhalt „\(contentContains)“ nicht in der Datei gefunden.")
            }

        case .unlock:
            break // handled in run(url:)

        case .damaged(let originalPageCount, let originalBytes):
            guard let url = fileURL, let data = try? Data(contentsOf: url) else {
                fail("damaged: Datei nicht lesbar.")
                return
            }
            if data.count >= originalBytes {
                fail("damaged: Datei wurde nicht verkleinert (\(data.count) >= \(originalBytes) Bytes).")
            }
            if pdfDoc == nil {
                note("PDFDocument öffnet die beschädigte Datei nicht (erwartet für 'damaged'); Original: \(originalPageCount) Seiten, gekürzt auf \(data.count) von \(originalBytes) Bytes.")
                return
            }
            let pages = pdfDoc?.pageCount ?? 0
            if pages >= originalPageCount {
                fail("damaged: Datei öffnet vollständig mit \(pages) Seiten, erwartet < \(originalPageCount).")
            } else {
                note("Datei ist wie erwartet beschädigt – PDFKit meldet \(pages) Seite(n), Original \(originalPageCount); gekürzt auf \(data.count) von \(originalBytes) Bytes.")
            }

        case .privacyScan(let string, let label):
            guard let data = fileURL.flatMap({ try? Data(contentsOf: $0) }) else { return }
            if data.range(of: Data(string.utf8)) != nil {
                fail("Datenschutz: Datei enthält „\(label)“ (\(string)) – darf nicht in Fixtures landen.")
            }
        }
    }

    // MARK: page text + geometry check

    private mutating func checkPageText(page: Int, needle: String, occurrence: Int,
                                        rects: [CGRect], note: String) {
        guard let doc = pdfDoc, let p = doc.page(at: page) else {
            fail("Seite \(page) fehlt für Textprüfung „\(needle)“.")
            return
        }
        guard let s = p.string else {
            fail("Seite \(page) hat keinen extrahierbaren Text („\(note)“).")
            return
        }
        let matches = NormalizedText(s).rawRanges(of: needle)
        guard !matches.isEmpty else {
            fail("Seite \(page): Text „\(needle)“ (\(note)) nicht im Seiteninhalt gefunden.")
            return
        }
        // String-presence-only check (no geometry to compare).
        guard !rects.isEmpty else { return }
        guard occurrence < matches.count else {
            fail("Seite \(page): „\(needle)“ hat nur \(matches.count) Treffer, erwartet Treffer Nr. \(occurrence).")
            return
        }
        let parts = needle.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1 {
            var searchFrom = 0
            let ns = s as NSString
            for (i, part) in parts.enumerated() {
                guard i < rects.count else { break }
                let r = ns.range(of: part, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                guard r.location != NSNotFound else {
                    fail("Seite \(page): Zeilenteil „\(part)“ von „\(needle)“ nicht gefunden.")
                    return
                }
                guard let sel = p.selection(for: r) else {
                    fail("Seite \(page): keine Auswahlgeometrie für „\(part)“.")
                    return
                }
                let selBounds = sel.bounds(for: p)
                guard !selBounds.isNull, !selBounds.isEmpty else {
                    fail("Seite \(page): leere Auswahlgeometrie für „\(part)“.")
                    return
                }
                if !rects[i].inflated(by: 2).intersects(selBounds) {
                    fail("Seite \(page): Rect \(i) \(rects[i]) von „\(needle)“ schneidet die PDFKit-Auswahl \(selBounds) nicht.")
                }
                searchFrom = r.location + r.length
            }
        } else {
            let r = matches[occurrence]
            guard let sel = p.selection(for: r) else {
                fail("Seite \(page): keine Auswahlgeometrie für „\(needle)“ (Treffer \(occurrence)).")
                return
            }
            let selBounds = sel.bounds(for: p)
            guard !selBounds.isNull, !selBounds.isEmpty else {
                fail("Seite \(page): leere Auswahlgeometrie für „\(needle)“ (Treffer \(occurrence)).")
                return
            }
            if !rects.contains(where: { $0.inflated(by: 2).intersects(selBounds) }) {
                fail("Seite \(page): Rects \(rects) von „\(needle)“ (Treffer \(occurrence)) schneiden die PDFKit-Auswahl \(selBounds) nicht.")
            }
        }
    }

    // MARK: content stream (flate) inspection

    /// True if the (possibly Flate-compressed) content stream of the page
    /// contains `needle`. CoreGraphics emits text as many small show strings
    /// with kerning values, so the string literals of the stream are
    /// extracted in order and concatenated before searching.
    private func contentStreamContains(data: Data, page: Int, needle: String) -> Bool {
        guard let raw = RawPDF.parse(data) else { return false }
        let pages = raw.pageObjectNumbers()
        guard page < pages.count else { return false }
        let body = raw.body(of: pages[page])
        guard let m = firstMatch("/Contents\\s+(\\d+)\\s+\\d+\\s+R", in: body as NSString) else { return false }
        let contentNumber = Int(group(body as NSString, m, 1)) ?? 0
        guard let obj = raw.objects[contentNumber] else { return false }
        let ns = raw.string
        let streamRange = ns.range(of: "stream", range: NSRange(location: obj.bodyStart, length: obj.bodyEnd - obj.bodyStart))
        guard streamRange.location != NSNotFound else { return false }
        var ds = streamRange.location + streamRange.length
        while ds < ns.length, [0x0A, 0x0D].contains(ns.character(at: ds)) { ds += 1 }
        // Exact stream length from /Length, with endstream as fallback.
        let dictText = ns.substring(with: NSRange(location: obj.bodyStart, length: streamRange.location - obj.bodyStart))
        var end: Int
        if let lm = firstMatch("/Length\\s+(\\d+)", in: dictText as NSString) {
            end = ds + (Int(group(dictText as NSString, lm, 1)) ?? 0)
        } else {
            let es = ns.range(of: "endstream", range: NSRange(location: ds, length: ns.length - ds))
            guard es.location != NSNotFound else { return false }
            end = es.location
        }
        guard end > ds, end <= data.count else { return false }
        let compressed = data.subdata(in: ds..<end)
        var contentText: String?
        if dictText.contains("/FlateDecode") {
            // PDF FlateDecode = RFC 1950 (zlib header + adler32); Apple's
            // COMPRESSION_ZLIB is raw deflate, so strip the 2-byte header.
            let rawDeflate = compressed.count > 2 ? Data(compressed.dropFirst(2)) : compressed
            if let inflated = try? (rawDeflate as NSData).decompressed(using: .zlib),
               let text = String(data: inflated as Data, encoding: .isoLatin1) {
                contentText = text
            }
        } else {
            contentText = String(data: compressed, encoding: .isoLatin1)
        }
        guard let content = contentText else { return false }
        return textLiterals(in: content).contains(needle)
    }

    /// Concatenates all PDF string literals of a content stream in order
    /// (escapes \( \) \\ resolved).
    private func textLiterals(in content: String) -> String {
        var out = ""
        let chars = Array(content.unicodeScalars)
        var i = 0
        while i < chars.count {
            if chars[i] == "(" {
                var depth = 1
                i += 1
                var literal = ""
                while i < chars.count, depth > 0 {
                    let c = chars[i]
                    if c == "\\", i + 1 < chars.count {
                        let n = chars[i + 1]
                        switch n {
                        case "(": literal.append("(")
                        case ")": literal.append(")")
                        case "\\": literal.append("\\")
                        case "n": literal.append("\n")
                        case "r": literal.append("\r")
                        case "t": literal.append("\t")
                        default: literal.unicodeScalars.append(n)
                        }
                        i += 2
                        continue
                    }
                    if c == "(" { depth += 1 }
                    if c == ")" {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    literal.unicodeScalars.append(c)
                    i += 1
                }
                out += literal
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: rendering helpers

    private func pageString(_ index: Int) -> String? {
        pdfDoc?.page(at: index)?.string
    }

    private func renderImage(of page: Int) -> CGImage? {
        guard let p = pdfDoc?.page(at: page) else { return nil }
        let thumb = p.thumbnail(of: CGSize(width: 1190, height: 1683), for: .mediaBox)
        return thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Renders the page and checks that the rect area (page space, origin
    /// bottom-left) contains pixels darker than `threshold`. Scan pages always
    /// have rotation 0. The sampled area is inflated by 2 pt to tolerate the
    /// slight skew of degraded scans.
    private func hasDarkPixels(page: Int, in rect: CGRect, threshold: Int) -> Bool {
        guard let img = renderImage(of: page), let p = pdfDoc?.page(at: page) else { return false }
        let mb = p.bounds(for: .mediaBox)
        guard mb.width > 0, mb.height > 0 else { return false }
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: img.width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let buf = ctx.data else { return false }
        let ptr = buf.assumingMemoryBound(to: UInt8.self)
        // Bitmap memory row 0 is the TOP row; page space origin is bottom-left.
        let rect = rect.inflated(by: 2)
        let sx = CGFloat(img.width) / mb.width
        let sy = CGFloat(img.height) / mb.height
        let x0 = max(0, Int(rect.minX * sx)), x1 = min(img.width - 1, Int(rect.maxX * sx))
        let yBottom = max(0, Int(rect.minY * sy))                 // buffer row of the rect's lower edge
        let yTop = min(img.height - 1, Int(rect.maxY * sy))       // buffer row of the rect's upper edge
        let rowTop = img.height - 1 - yTop
        let rowBottom = img.height - 1 - yBottom
        guard x1 >= x0, rowBottom >= rowTop else { return false }
        let stepX = max(1, (x1 - x0) / 16)
        let stepY = max(1, (rowBottom - rowTop) / 16)
        var row = rowTop
        while row <= rowBottom {
            var x = x0
            while x <= x1 {
                if ptr[row * img.width + x] < threshold { return true }
                x += stepX
            }
            row += stepY
        }
        return false
    }
}
