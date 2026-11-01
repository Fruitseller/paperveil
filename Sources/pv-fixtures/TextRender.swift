import CoreGraphics
import CoreText
import Foundation

// MARK: - Font handling

struct FontSpec: Hashable {
    var name: String
    var size: CGFloat

    static func helvetica(_ s: CGFloat) -> FontSpec { .init(name: "Helvetica", size: s) }
    static func helveticaBold(_ s: CGFloat) -> FontSpec { .init(name: "Helvetica-Bold", size: s) }
    static func helveticaOblique(_ s: CGFloat) -> FontSpec { .init(name: "Helvetica-Oblique", size: s) }
    static func courier(_ s: CGFloat) -> FontSpec { .init(name: "Courier", size: s) }
    static func courierBold(_ s: CGFloat) -> FontSpec { .init(name: "Courier-Bold", size: s) }
    static func zapfino(_ s: CGFloat) -> FontSpec { .init(name: "Zapfino", size: s) }

    func ctFont() -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
}

let kFontBlack = CGColor(gray: 0.05, alpha: 1)
let kFontGray = CGColor(gray: 0.35, alpha: 1)
let kFontWhite = CGColor(gray: 1.0, alpha: 1)

// MARK: - A drawn line with exact geometry

/// One line of text drawn into a CGContext. `rect` is the exact typographic
/// bounding box (baseline minus descent, ascent plus descent) in the
/// coordinate space the caller drew in. Substring rects are derived from the
/// CTLine pen offsets, so they are exact as well.
struct DrawnLine {
    let text: String
    let line: CTLine
    /// Baseline start point in page space.
    let baseline: CGPoint
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    var rect: CGRect {
        CGRect(x: baseline.x, y: baseline.y - descent, width: width, height: ascent + descent)
    }

    /// Exact rect of the occurrence-th occurrence of `substring` within the
    /// drawn line. Falls back to the whole-line rect when the substring cannot
    /// be located (should not happen for generated content).
    func rect(of substring: String, occurrence: Int = 0) -> CGRect {
        let ns = text as NSString
        var remaining = NSRange(location: 0, length: ns.length)
        var found = 0
        var match = NSRange(location: NSNotFound, length: 0)
        while remaining.length > 0 || remaining.location < ns.length {
            let r = ns.range(of: substring, range: NSRange(location: remaining.location,
                                                            length: ns.length - remaining.location))
            guard r.location != NSNotFound else { break }
            if found == occurrence { match = r; break }
            found += 1
            remaining.location = r.location + r.length
        }
        guard match.location != NSNotFound, match.length > 0 else { return rect }
        let x0 = CTLineGetOffsetForStringIndex(line, match.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(line, match.location + match.length, nil)
        let w = abs(x1 - x0)
        guard w > 0.01 else { return rect }
        return CGRect(x: baseline.x + min(x0, x1), y: baseline.y - descent, width: w, height: ascent + descent)
    }
}

// MARK: - CoreText drawing

enum TextRender {
    static func attributes(_ font: FontSpec, _ color: CGColor) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): font.ctFont(),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
    }

    /// Width the text would occupy (points).
    static func width(of text: String, font: FontSpec) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attr = NSAttributedString(string: text, attributes: attributes(font, kFontBlack))
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draw a single line at a baseline point. Returns exact geometry.
    @discardableResult
    static func draw(_ ctx: CGContext, _ text: String, font: FontSpec, at baseline: CGPoint,
                     color: CGColor = kFontBlack) -> DrawnLine {
        let attr = NSAttributedString(string: text, attributes: attributes(font, color))
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.textPosition = baseline
        CTLineDraw(line, ctx)
        return DrawnLine(text: text, line: line, baseline: baseline,
                         ascent: CGFloat(ascent), descent: CGFloat(descent), width: CGFloat(w))
    }

    /// Greedy word wrap (deterministic; no hyphenation).
    static func wrap(_ text: String, font: FontSpec, maxWidth: CGFloat) -> [String] {
        var lines: [String] = []
        var current: [String] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = (current.isEmpty ? "" : current.joined(separator: " ") + " ") + word
            if !current.isEmpty, TextRender.width(of: candidate, font: font) > maxWidth {
                lines.append(current.joined(separator: " "))
                current = [String(word)]
            } else {
                current.append(String(word))
            }
        }
        if !current.isEmpty { lines.append(current.joined(separator: " ")) }
        return lines
    }

    /// Draw a wrapped paragraph. Returns one DrawnLine per rendered line.
    @discardableResult
    static func drawParagraph(_ ctx: CGContext, _ text: String, font: FontSpec,
                              at origin: CGPoint, maxWidth: CGFloat, leading: CGFloat,
                              color: CGColor = kFontBlack) -> [DrawnLine] {
        var result: [DrawnLine] = []
        var y = origin.y
        for lineText in wrap(text, font: font, maxWidth: maxWidth) {
            result.append(draw(ctx, lineText, font: font, at: CGPoint(x: origin.x, y: y), color: color))
            y -= leading
        }
        return result
    }
}

// MARK: - CGPoint/CGRect helpers

extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

extension CGRect {
    /// Rect standardized and grown by a margin on every side (for generous,
    /// conservative redaction areas).
    func inflated(by m: CGFloat) -> CGRect {
        CGRect(x: minX - m, y: minY - m, width: width + 2 * m, height: height + 2 * m)
    }
}

/// Deterministic RNG (splitmix64) — fixed seeds keep output reproducible.
struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(in range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
