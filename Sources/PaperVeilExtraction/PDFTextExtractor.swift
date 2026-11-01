import Foundation
import PDFKit
import PaperVeilCore

/// Extracts selectable PDF text with per-word geometry using PDFKit selections.
///
/// All rectangles are in *unrotated page space* (points, coordinate system of
/// `PDFPage.bounds(for: .mediaBox)`, independent of /Rotate). Lines are grouped
/// in reading order of the page *as displayed* — i.e. /Rotate is taken into
/// account when deciding which line comes first.
public struct PDFTextExtractor: Sendable {
    public init() {}

    /// Extracts text of every page of the document. Pages without selectable
    /// text produce an empty `PageText`.
    public func extract(from document: PDFDocument) -> [PageText] {
        (0..<document.pageCount).map { pageIndex in
            guard let page = document.page(at: pageIndex) else {
                return PageText(pageIndex: pageIndex, words: [])
            }
            return PageText(pageIndex: pageIndex, words: extractWords(page: page, pageIndex: pageIndex))
        }
    }

    /// Words of a single page in reading order. Empty when the page has no
    /// selectable text (e.g. a scanned image page).
    public func extractWords(page: PDFPage, pageIndex: Int) -> [TextWord] {
        guard let pageString = page.string, !pageString.isEmpty else { return [] }
        let ns = pageString as NSString
        guard ns.length > 0,
              let fullSelection = page.selection(for: NSRange(location: 0, length: ns.length)) else { return [] }

        let geometry = PageGeometry(crop: page.bounds(for: .cropBox), rotation: page.rotation)

        // 1. One selection per visual line, with its ranges in the page string.
        struct LineSegment {
            var bounds: CGRect
            var ranges: [NSRange] = []
        }
        var segments: [LineSegment] = []
        for lineSelection in fullSelection.selectionsByLine() {
            let rangeCount = lineSelection.numberOfTextRanges(on: page)
            guard rangeCount > 0 else { continue }
            var ranges: [NSRange] = []
            for i in 0..<rangeCount {
                ranges.append(lineSelection.range(at: i, on: page))
            }
            segments.append(LineSegment(bounds: lineSelection.bounds(for: page), ranges: ranges))
        }
        // Reading order of the page as displayed (respects /Rotate); stable, so
        // PDFKit's order is kept for unrotated pages.
        segments.sort { geometry.readingOrderKey(for: $0.bounds) < geometry.readingOrderKey(for: $1.bounds) }

        // 2. Split each line into whitespace-separated words; per-word geometry
        //    comes from a word-range selection on the page string.
        var words: [TextWord] = []
        for (lineNumber, segment) in segments.enumerated() {
            for range in segment.ranges {
                let lineText = ns.substring(with: range)
                let lineNSString = lineText as NSString
                var index = 0
                while index < lineNSString.length {
                    // Skip whitespace between words.
                    while index < lineNSString.length, isSeparator(lineNSString.character(at: index)) {
                        index += 1
                    }
                    guard index < lineNSString.length else { break }
                    let start = index
                    while index < lineNSString.length, !isSeparator(lineNSString.character(at: index)) {
                        index += 1
                    }
                    let localWord = NSRange(location: start, length: index - start)
                    let wordText = lineNSString.substring(with: localWord)
                    let pageRange = NSRange(location: range.location + start, length: localWord.length)
                    let rect = wordRect(pageRange: pageRange, fallback: segment.bounds, page: page)
                    words.append(TextWord(
                        text: wordText,
                        rect: rect,
                        source: .pdfText,
                        confidence: 1,
                        line: lineNumber
                    ))
                }
            }
        }
        return words
    }

    /// Geometry of one word. Falls back to the whole line's bounds in the rare
    /// case PDFKit refuses to build a selection for a word range (conservative:
    /// over-covers rather than losing the word).
    private func wordRect(pageRange: NSRange, fallback: CGRect, page: PDFPage) -> PageRect {
        if let selection = page.selection(for: pageRange) {
            let bounds = selection.bounds(for: page)
            if !bounds.isNull && !bounds.isEmpty { return PageRect(bounds) }
        }
        return PageRect(fallback)
    }

    /// Word separators: whitespace and newlines (incl. non-breaking space, which
    /// does not glue words together for redaction purposes).
    private func isSeparator(_ character: unichar) -> Bool {
        switch character {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0xA0: true
        default: false
        }
    }
}
