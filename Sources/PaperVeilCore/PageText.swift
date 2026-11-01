import Foundation

/// A word (or OCR token) with its location in page space.
public struct TextWord: Hashable, Codable, Sendable {
    public var text: String
    public var rect: PageRect
    public var source: TextSource
    /// 1.0 for PDF text; Vision confidence for OCR.
    public var confidence: Double
    /// Reading-order line number on the page.
    public var line: Int
    public init(text: String, rect: PageRect, source: TextSource, confidence: Double, line: Int) {
        self.text = text; self.rect = rect; self.source = source; self.confidence = confidence; self.line = line
    }
}

/// Extracted text of one page. `text` is built from `words`: words on the same
/// line are joined by a single space, lines by "\n". Every character range in
/// `text` maps back to word rectangles, which is how detections get geometry.
public struct PageText: Hashable, Codable, Sendable {
    public var pageIndex: Int
    public var words: [TextWord]
    public let text: String
    /// UTF-16 range of each word in `text` (parallel to `words`).
    public let wordRanges: [NSRange]

    public init(pageIndex: Int, words: [TextWord]) {
        self.pageIndex = pageIndex
        self.words = words
        var s = ""
        var ranges: [NSRange] = []
        var lastLine: Int?
        for w in words {
            if let l = lastLine { s += (l == w.line ? " " : "\n") }
            let start = (s as NSString).length
            s += w.text
            ranges.append(NSRange(location: start, length: (w.text as NSString).length))
            lastLine = w.line
        }
        self.text = s
        self.wordRanges = ranges
    }

    public var isOCR: Bool { words.contains { $0.source == .ocr } }

    /// Indices of words overlapping a UTF-16 range of `text`.
    public func wordIndices(overlapping range: NSRange) -> [Int] {
        wordRanges.indices.filter { NSIntersectionRange(wordRanges[$0], range).length > 0 }
    }

    /// Rectangles covering the range: one union rect per line. Partial words
    /// are covered fully (conservative: over-redact rather than under-redact).
    public func rects(for range: NSRange) -> [PageRect] {
        let idx = wordIndices(overlapping: range)
        var byLine: [Int: PageRect] = [:]
        var order: [Int] = []
        for i in idx {
            let w = words[i]
            if let r = byLine[w.line] { byLine[w.line] = r.union(w.rect) } else { byLine[w.line] = w.rect; order.append(w.line) }
        }
        return order.compactMap { byLine[$0] }
    }

    /// Minimum OCR confidence over a range (1.0 if none are OCR).
    public func minConfidence(for range: NSRange) -> Double {
        wordIndices(overlapping: range).map { words[$0].confidence }.min() ?? 1.0
    }
}

public struct DetectionResult: Sendable {
    public var findings: [Finding]
    public var warnings: [ProcessingWarning]
    public init(findings: [Finding] = [], warnings: [ProcessingWarning] = []) {
        self.findings = findings; self.warnings = warnings
    }
}
