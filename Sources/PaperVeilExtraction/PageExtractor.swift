import Foundation
import PDFKit
import PaperVeilCore

/// Result of extracting text from a whole document.
public struct ExtractionResult: Sendable {
    /// One entry per page, in page order. Pages without any text are empty.
    public let pages: [PageText]
    /// Warnings that block approval until the user acknowledges them
    /// (OCR-only pages, low OCR confidence).
    public let warnings: [ProcessingWarning]

    public init(pages: [PageText], warnings: [ProcessingWarning]) {
        self.pages = pages
        self.warnings = warnings
    }
}

/// Extracts text from a PDF per page: selectable PDF text where meaningful,
/// Vision OCR for scan pages — and for mixed pages (text plus a large image)
/// OCR results merged with the PDF text, de-duplicating OCR words that overlap
/// existing PDF words.
///
/// The function is nonisolated and async, so the heavy PDFKit/Vision work runs
/// on the global concurrent executor: it never blocks the main actor even when
/// awaited from there (SE-0338). Cancellation is honoured between pages.
public struct PageExtractor: Sendable {
    /// OCR words that overlap an existing PDF word by at least this fraction of
    /// the OCR word's area are considered duplicates of the text layer.
    private static let duplicateOverlapFraction = 0.25

    private let pdfTextExtractor: PDFTextExtractor
    private let ocrExtractor: OCRExtractor
    private let imageAnalyzer: PageImageAnalyzer

    public init() {
        self.pdfTextExtractor = PDFTextExtractor()
        self.ocrExtractor = OCRExtractor()
        self.imageAnalyzer = PageImageAnalyzer()
    }

    /// Extracts all pages of the validated-or-not PDF at `url`.
    ///
    /// - Parameters:
    ///   - url: the original PDF. Opened read-only; never modified.
    ///   - documentID: neutral id of the document this extraction belongs to
    ///     (reserved for caller-side correlation; the extraction itself is
    ///     independent of it).
    /// - Throws: `InputError` for unusable inputs, `CancellationError` when the
    ///   task is cancelled, and Vision errors if OCR fails hard.
    public func extract(url: URL, documentID: DocumentID) async throws -> ExtractionResult {
        try Task.checkCancellation()
        let validated = try InputValidator.validate(url: url)
        let document = validated.document

        var pages: [PageText] = []
        var warnings: [ProcessingWarning] = []

        for pageIndex in 0..<validated.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                pages.append(PageText(pageIndex: pageIndex, words: []))
                continue
            }

            let pdfWords = pdfTextExtractor.extractWords(page: page, pageIndex: pageIndex)
            let hasMeaningfulText = Self.hasMeaningfulText(pdfWords)
            let hasLargeImage = imageAnalyzer.containsLargeImage(page: page)

            // PDF text alone is enough when the page has real text and no large
            // image (a scan with a text layer or a mixed page needs OCR).
            if hasMeaningfulText && !hasLargeImage {
                pages.append(PageText(pageIndex: pageIndex, words: pdfWords))
                continue
            }

            let ocrWords = try await ocrExtractor.extractWords(page: page, pageIndex: pageIndex)
            let keptOCRWords = hasMeaningfulText
                ? Self.deduplicated(ocrWords: ocrWords, against: pdfWords)
                : ocrWords
            let geometry = PageGeometry(crop: page.bounds(for: .cropBox), rotation: page.rotation)
            let words = Self.merged(pdfWords: pdfWords, ocrWords: keptOCRWords, geometry: geometry)
            pages.append(PageText(pageIndex: pageIndex, words: words))
            warnings.append(contentsOf: Self.warnings(for: words, pageIndex: pageIndex))
        }
        return ExtractionResult(pages: pages, warnings: warnings)
    }

    // MARK: - Warnings

    /// Warnings derived from a page's final word list: every page whose text
    /// (partly) comes from OCR is marked as derived; any OCR word with low
    /// confidence gets an explicit warning.
    static func warnings(for words: [TextWord], pageIndex: Int) -> [ProcessingWarning] {
        var result: [ProcessingWarning] = []
        let ocrWords = words.filter { $0.source == .ocr }
        if !ocrWords.isEmpty {
            result.append(ProcessingWarning(
                kind: .ocrOnlyPage,
                pageIndex: pageIndex,
                message: "Text dieser Seite stammt aus OCR und ist abgeleitet."
            ))
        }
        if let minimum = ocrWords.map(\.confidence).min(),
           minimum < OCRExtractor.lowConfidenceThreshold {
            let formatted = String(format: "%.1f", minimum).replacingOccurrences(of: ".", with: ",")
            result.append(ProcessingWarning(
                kind: .lowOCRConfidence,
                pageIndex: pageIndex,
                message: "Unsichere OCR-Erkennung auf dieser Seite (geringste Konfidenz \(formatted) < 0,5). Bitte Text manuell prüfen."
            ))
        }
        return result
    }

    // MARK: - Page classification

    /// A page has "meaningful" PDF text when there is more than a stray fragment
    /// (e.g. a lone page number would not count and the page gets OCR'd).
    static func hasMeaningfulText(_ words: [TextWord]) -> Bool {
        let characterCount = words.map { $0.text.count }.reduce(0, +)
        return words.count >= 2 && characterCount >= 12
    }

    // MARK: - Merging PDF and OCR text

    /// Drops OCR words that substantially overlap a PDF word: on mixed pages the
    /// PDF text layer is the original text; the OCR copy of the same glyphs is
    /// derived and must not duplicate it.
    static func deduplicated(ocrWords: [TextWord], against pdfWords: [TextWord]) -> [TextWord] {
        guard !pdfWords.isEmpty, !ocrWords.isEmpty else { return ocrWords }
        return ocrWords.filter { ocr in
            let ocrRect = ocr.rect.cgRect
            let ocrArea = ocrRect.width * ocrRect.height
            guard ocrArea > 0 else { return true }
            for pdf in pdfWords {
                let intersection = ocrRect.intersection(pdf.rect.cgRect)
                guard !intersection.isNull else { continue }
                let overlap = (intersection.width * intersection.height) / ocrArea
                if overlap >= duplicateOverlapFraction { return false }
            }
            return true
        }
    }

    /// Merges PDF and OCR words into one reading order: lines are interleaved by
    /// their position on the page as displayed (respects /Rotate), then line
    /// numbers are assigned sequentially.
    static func merged(pdfWords: [TextWord], ocrWords: [TextWord], geometry: PageGeometry) -> [TextWord] {
        guard !pdfWords.isEmpty else { return ocrWords }
        guard !ocrWords.isEmpty else { return pdfWords }

        struct LineGroup {
            let source: Int              // stable tie-breaker: PDF before OCR
            let originalLine: Int
            let anchor: (Double, Double) // reading-order key of the line's rect
            var words: [TextWord]
        }
        var pdfGroups: [Int: LineGroup] = [:]
        for word in pdfWords {
            if pdfGroups[word.line] == nil {
                pdfGroups[word.line] = LineGroup(source: 0, originalLine: word.line,
                                                 anchor: geometry.readingOrderKey(for: word.rect.cgRect), words: [])
            }
            pdfGroups[word.line]!.words.append(word)
        }
        var ocrGroups: [Int: LineGroup] = [:]
        for word in ocrWords {
            if ocrGroups[word.line] == nil {
                ocrGroups[word.line] = LineGroup(source: 1, originalLine: word.line,
                                                 anchor: geometry.readingOrderKey(for: word.rect.cgRect), words: [])
            }
            ocrGroups[word.line]!.words.append(word)
        }

        let sorted = (Array(pdfGroups.values) + Array(ocrGroups.values)).sorted { a, b in
            if a.anchor != b.anchor { return a.anchor < b.anchor }
            if a.source != b.source { return a.source < b.source }
            return a.originalLine < b.originalLine
        }

        var result: [TextWord] = []
        for (newLineNumber, group) in sorted.enumerated() {
            result.append(contentsOf: group.words.map { word in
                TextWord(text: word.text, rect: word.rect, source: word.source,
                         confidence: word.confidence, line: newLineNumber)
            })
        }
        return result
    }
}
