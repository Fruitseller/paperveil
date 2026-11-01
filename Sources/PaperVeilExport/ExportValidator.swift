import CoreGraphics
import Foundation
import PDFKit
import PaperVeilCore

/// Independent re-validation of a finished export (Zielzustand C06).
public struct ExportValidationReport: Sendable {
    public let passed: Bool
    /// German messages; failures first, then informational measurements.
    public let messages: [String]
    /// Mean absolute per-channel pixel difference (0–255) outside the
    /// redaction masks, per page.
    public let pageMeanAbsoluteDifferences: [Double]

    public init(passed: Bool, messages: [String], pageMeanAbsoluteDifferences: [Double]) {
        self.passed = passed
        self.messages = messages
        self.pageMeanAbsoluteDifferences = pageMeanAbsoluteDifferences
    }
}

/// Re-opens a finished export and checks it against the original document
/// and the approved findings. All checks run on freshly opened files; the
/// exporter's claims are not trusted.
///
/// Thresholds:
/// - near-black inside a redaction rect (shrunk by 1 px): every channel
///   ≤ 32 (0–255), required for ≥ 99% of the pixels;
/// - mean absolute per-channel difference outside the redaction rects
///   (expanded by the export padding plus 4 px): ≤ 1.0 (0–255 scale),
///   measured per page and reported in `messages`.
public enum ExportValidator {
    /// Channels at or below this value count as "near-black".
    private static let nearBlackChannelMax: UInt8 = 32
    /// Minimum fraction of near-black pixels inside a redaction rect.
    private static let requiredBlackRatio = 0.99
    /// Mean absolute per-channel difference allowed outside the masks.
    private static let maxMeanAbsoluteDifference = 1.0
    /// Extra margin (px) added to the padding when masking the comparison.
    private static let outsideMarginPx = 4.0
    /// Info-dictionary keys a PaperVeil export may contain. Everything else —
    /// in particular Title, Author, Subject, Keywords — is a side channel.
    private static let allowedInfoKeys: Set<String> = ["Creator", "Producer", "CreationDate", "ModDate", "Version"]
    /// Catalog entries an export must not contain.
    private static let forbiddenCatalogKeys: Set<String> = ["AcroForm", "OpenAction", "AA", "JavaScript", "Outlines"]
    private static let dateKeys: Set<String> = ["CreationDate", "ModDate"]

    public static func validate(export: URL, original: URL, findings: [Finding],
                                dpi: Double = 300, padding: Double = 2) -> ExportValidationReport {
        var failures: [String] = []
        var info: [String] = []

        func fail(_ message: String) { failures.append(message) }

        // Original integrity is part of every validation.
        guard let originalHashBefore = try? SHA256Hex.of(fileAt: original) else {
            return ExportValidationReport(
                passed: false,
                messages: ["Original kann nicht gelesen werden; Hash nicht bestimmbar."],
                pageMeanAbsoluteDifferences: []
            )
        }

        // (a) Opens with PDFKit and CGPDFDocument; not encrypted.
        guard let exportDocument = PDFDocument(url: export), exportDocument.pageCount > 0 else {
            return ExportValidationReport(
                passed: false,
                messages: ["Export lässt sich mit PDFKit nicht öffnen oder enthält keine Seiten."],
                pageMeanAbsoluteDifferences: []
            )
        }
        guard let exportPDF = CGPDFDocument(export as CFURL), exportPDF.numberOfPages > 0 else {
            return ExportValidationReport(
                passed: false,
                messages: ["Export lässt sich mit CGPDFDocument nicht öffnen."],
                pageMeanAbsoluteDifferences: []
            )
        }
        if exportDocument.isEncrypted {
            fail("Export ist verschlüsselt; das ist für PaperVeil-Exporte nicht vorgesehen.")
        }

        // (b) Page count, order and orientation equal the original.
        guard let originalPDF = CGPDFDocument(original as CFURL), originalPDF.numberOfPages > 0 else {
            return ExportValidationReport(
                passed: false,
                messages: ["Original lässt sich mit CGPDFDocument nicht öffnen."] + failures,
                pageMeanAbsoluteDifferences: []
            )
        }
        if exportPDF.numberOfPages != originalPDF.numberOfPages {
            fail("Seitenzahl weicht ab: Export \(exportPDF.numberOfPages), Original \(originalPDF.numberOfPages).")
        }
        if let exportKitDocument = PDFDocument(url: export), exportKitDocument.pageCount != exportPDF.numberOfPages {
            fail("PDFKit und CGPDFDocument melden unterschiedliche Seitenzahlen.")
        }

        let redactedRectsByPage: [Int: [CGRect]] = Dictionary(
            grouping: findings.filter(\.isRedacted),
            by: \.pageIndex
        ).mapValues { fs in fs.flatMap { $0.rects.map(\.cgRect) } }
        for (pageIndex, _) in redactedRectsByPage.sorted(by: { $0.key < $1.key })
        where pageIndex < 0 || pageIndex >= exportPDF.numberOfPages {
            fail("Fundstelle verweist auf die nicht vorhandene Seite \(pageIndex + 1).")
        }

        // (c) No text layer.
        let exportText = (exportDocument.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !exportText.isEmpty {
            fail("Export enthält eine Textebene mit \(exportText.count) Zeichen; erwartet: keine.")
        }

        // (d) No annotations on any page.
        var annotationCount = 0
        for index in 0..<exportDocument.pageCount {
            let annotations = exportDocument.page(at: index)?.annotations ?? []
            annotationCount += annotations.count
        }
        if annotationCount > 0 {
            fail("Export enthält \(annotationCount) Annotation(en); erwartet: keine.")
        }

        // (e) Neutral metadata, nothing inherited from the original.
        let exportAttributes = exportDocument.documentAttributes ?? [:]
        for case let key as String in exportAttributes.keys where !allowedInfoKeys.contains(key) {
            fail("Metadaten enthalten den nicht erlaubten Schlüssel „\(key)“.")
        }
        let exportStructure = PDFStructure.parse(data: (try? Data(contentsOf: export)) ?? Data())
        let originalStructure = PDFStructure.parse(data: (try? Data(contentsOf: original)) ?? Data())
        for key in exportStructure.infoDictionary.keys where !allowedInfoKeys.contains(key) {
            fail("Info-Wörterbuch enthält den nicht erlaubten Schlüssel /\(key).")
        }
        var originalValues: [String] = Array(originalStructure.infoDictionary.values)
        if let originalKit = PDFDocument(url: original) {
            for (_, value) in originalKit.documentAttributes ?? [:] {
                if let s = value as? String { originalValues.append(s) }
            }
        }
        let leaks = originalValues.filter { $0.count >= 4 }
        for (key, value) in exportStructure.infoDictionary
        where !dateKeys.contains(key) && leaks.contains(where: value.contains) {
            fail("Metadatenwert „\(key)“ enthält Daten aus dem Original.")
        }

        // (f) Catalog and page structure contain no side channels.
        if !exportStructure.parsingComplete {
            fail("Die PDF-Struktur des Exports konnte nicht vollständig geprüft werden.")
        }
        for key in exportStructure.catalogKeys where forbiddenCatalogKeys.contains(key) {
            fail("Katalog enthält den verbotenen Eintrag /\(key).")
        }
        if exportStructure.hasEmbeddedFiles {
            fail("Export enthält eingebettete Dateien (Names/EmbeddedFiles).")
        }
        if exportStructure.isEncrypted {
            fail("Export enthält ein Encrypt-Wörterbuch.")
        }
        for (index, page) in exportStructure.pages.enumerated()
       where exportStructure.resolve(page["Annots"])?.arrayValue?.isEmpty == false {
            fail("Seite \(index + 1) enthält Annotationen (/Annots).")
        }

        // (g) Pixel-level comparison with an independent re-render.
        let pageCount = min(exportPDF.numberOfPages, originalPDF.numberOfPages)
        var pageDiffs: [Double] = []
        for pageIndex in 0..<pageCount {
            guard let exportPage = exportPDF.page(at: pageIndex + 1),
                  let originalPage = originalPDF.page(at: pageIndex + 1),
                  let exportBitmap = PageBitmap(page: exportPage, dpi: dpi),
                  let originalBitmap = PageBitmap(page: originalPage, dpi: dpi)
            else {
                fail("Seite \(pageIndex + 1) konnte für den Pixelvergleich nicht gerendert werden.")
                pageDiffs.append(-1)
                continue
            }

            // Orientation and displayed size must match the original.
            let e = exportBitmap.geometry.displayedSize
            let o = originalBitmap.geometry.displayedSize
            if abs(e.width - o.width) > 0.5 || abs(e.height - o.height) > 0.5 {
                fail("Seite \(pageIndex + 1): angezeigte Größe weicht ab (\(e) statt \(o)).")
            }
            if (e.width > e.height) != (o.width > o.height) {
                fail("Seite \(pageIndex + 1): Orientierung weicht ab.")
            }

            let rects = (redactedRectsByPage[pageIndex] ?? []).map { originalBitmap.pixelRect(forUserRect: $0) }

            // Inside: near-black after shrinking by 1 px.
            for rect in rects {
                let clipped = rect.intersection(exportBitmap.deviceBounds)
                if clipped.width < 3 || clipped.height < 3 {
                    fail("Seite \(pageIndex + 1): Ein Schwärzungsbereich liegt vollständig außerhalb des sichtbaren Seitenbereichs.")
                    continue
                }
                let bounds = exportBitmap.pixelBounds(of: clipped, inset: 1)
                var black = 0
                var total = 0
                for y in bounds.y0..<bounds.y1 {
                    for x in bounds.x0..<bounds.x1 {
                        let c = exportBitmap.rgb(x: x, y: y)
                        if c.r <= nearBlackChannelMax && c.g <= nearBlackChannelMax && c.b <= nearBlackChannelMax {
                            black += 1
                        }
                        total += 1
                    }
                }
                let ratio = total > 0 ? Double(black) / Double(total) : 1
                if ratio < requiredBlackRatio {
                    fail("Seite \(pageIndex + 1): Schwärzung nur zu \(Int((ratio * 100).rounded()))% schwarz (erforderlich: 99%).")
                }
            }

            // Outside: mean absolute difference vs the source render.
            let margin = padding * dpi / 72.0 + outsideMarginPx
            let excluded = rects.map { $0.insetBy(dx: -margin, dy: -margin) }
            let difference = meanAbsoluteDifference(original: originalBitmap, export: exportBitmap,
                                                    excluded: excluded)
            pageDiffs.append(difference ?? -1)
            if let difference {
                info.append(String(
                    format: "Seite %d: mittlere Pixelabweichung außerhalb der Schwärzungen: %.3f (Grenzwert %.1f).",
                    pageIndex + 1, difference, maxMeanAbsoluteDifference
                ))
                if difference > maxMeanAbsoluteDifference {
                    fail(String(
                        format: "Seite %d: Bildinhalte außerhalb der Schwärzungen weichen vom Original ab (%.3f).",
                        pageIndex + 1, difference
                    ))
                }
            }
        }

        // Original untouched by validation as well.
        if (try? SHA256Hex.of(fileAt: original)) != originalHashBefore {
            fail("Original-Hash hat sich während der Prüfung verändert.")
        }

        return ExportValidationReport(
            passed: failures.isEmpty,
            messages: failures + info,
            pageMeanAbsoluteDifferences: pageDiffs
        )
    }

    /// Mean absolute per-channel difference over all pixels outside the
    /// excluded rects. Returns nil when nothing is left to compare.
    private static func meanAbsoluteDifference(original: PageBitmap, export: PageBitmap,
                                               excluded: [CGRect]) -> Double? {
        guard original.width == export.width, original.height == export.height else { return nil }
        let width = original.width
        let height = original.height
        var mask = [Bool](repeating: false, count: width)
        var sum = 0.0
        var count = 0
        for y in 0..<height {
            if width > 0 { for x in mask.indices { mask[x] = false } }
            // Row y (from the top) covers device-space y in [height-y-1, height-y].
            for rect in excluded
            where (Double(height) - Double(y) - 1) < rect.maxY && (Double(height) - Double(y)) > rect.minY {
                let x0 = max(0, Int(rect.minX.rounded(.down)))
                let x1 = min(width, Int(rect.maxX.rounded(.up)))
                if x1 > x0 { for x in x0..<x1 { mask[x] = true } }
            }
            for x in 0..<width where !mask[x] {
                let a = original.rgb(x: x, y: y)
                let b = export.rgb(x: x, y: y)
                sum += abs(Double(a.r) - Double(b.r))
                sum += abs(Double(a.g) - Double(b.g))
                sum += abs(Double(a.b) - Double(b.b))
                count += 3
            }
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }
}
