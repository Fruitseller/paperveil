import CoreGraphics
import Foundation
import PaperVeilCore

/// Result of a raster export.
public struct ExportOutcome: Sendable {
    /// The final export file (never the original).
    public let url: URL
    /// SHA-256 of the export file.
    public let sha256: String
    public let pageCount: Int
    /// Rendered pixel size per page, in page order.
    public let pagePixelSizes: [CGSize]
    /// Dots per inch the pages were rendered with.
    public let dpi: Double
    public let fileSizeBytes: Int

    public init(url: URL, sha256: String, pageCount: Int, pagePixelSizes: [CGSize], dpi: Double, fileSizeBytes: Int) {
        self.url = url
        self.sha256 = sha256
        self.pageCount = pageCount
        self.pagePixelSizes = pagePixelSizes
        self.dpi = dpi
        self.fileSizeBytes = fileSizeBytes
    }
}

public enum ExportError: Error, Equatable, CustomStringConvertible {
    /// The destination is the original file (or an equivalent path).
    case destinationEqualsOriginal
    case originalUnreadable
    /// A finding refers to a page index outside the document.
    case findingOutsidePageRange(Int)
    case pageRenderingFailed(Int)
    case pdfWritingFailed
    /// The original changed while the export was running.
    case originalChangedDuringExport

    public var description: String {
        switch self {
        case .destinationEqualsOriginal:
            "Das Ziel darf nicht das Original sein. Der Export wird in eine separate Datei geschrieben."
        case .originalUnreadable:
            "Das Original-PDF kann nicht geöffnet werden."
        case .findingOutsidePageRange(let i):
            "Eine Fundstelle verweist auf die nicht vorhandene Seite \(i + 1)."
        case .pageRenderingFailed(let i):
            "Seite \(i) konnte nicht gerendert werden."
        case .pdfWritingFailed:
            "Der Export konnte nicht als PDF geschrieben werden."
        case .originalChangedDuringExport:
            "Das Original wurde während des Exports verändert. Der Export wurde verworfen."
        }
    }
}

/// Security-critical raster export (Zielzustand C02–C06).
///
/// Every page is rendered into an opaque white sRGB bitmap at `dpi` — as
/// displayed (cropBox honoured, `/Rotate` applied) — then every redacted
/// finding rect is expanded by `padding` points, mapped through the *same*
/// transform into pixel space and filled with solid black **into the pixels**.
/// The export is then a brand-new PDF (CGPDFContext) that contains only these
/// images: no text layer, no annotations, no forms, no outlines, no embedded
/// files, no inherited metadata.
///
/// Image encoding trade-off: bitmaps are embedded losslessly (Flate via
/// CGImage). JPEG at high quality would typically shrink photographic scans
/// by 5–10× but would re-compress the retained medical content and soften
/// fine print at the same time; lossless keeps every pixel outside the
/// masks byte-identical to the source render, which is what the export
/// validator's image comparison relies on. Lossless is therefore the default
/// and only mode.
public enum RasterExporter {
    /// Neutral document info for the export. Only these keys are ever set.
    private static let creator = "PaperVeil"

    public static func export(original: URL, findings: [Finding], to destination: URL,
                              dpi: Double = 300, padding: Double = 2) throws -> ExportOutcome {
        // C02: never write to the original, by path or by alias.
        let originalPath = original.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard originalPath != destinationPath else { throw ExportError.destinationEqualsOriginal }

        let originalHashBefore = try SHA256Hex.of(fileAt: original)
        guard let document = CGPDFDocument(original as CFURL), document.numberOfPages > 0 else {
            throw ExportError.originalUnreadable
        }
        let pageCount = document.numberOfPages

        // Redacted rect lists per page index (findings not explicitly rejected).
        var redactions: [Int: [CGRect]] = [:]
        for finding in findings where finding.isRedacted {
            guard finding.pageIndex >= 0, finding.pageIndex < pageCount else {
                throw ExportError.findingOutsidePageRange(finding.pageIndex)
            }
            redactions[finding.pageIndex, default: []].append(contentsOf: finding.rects.map(\.cgRect))
        }

        let fileManager = FileManager.default
        let destinationDir = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let tempURL = destinationDir.appendingPathComponent(".pv-export-\(UUID().uuidString).pdf")

        var tempStillExists = true
        defer {
            if tempStillExists, fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        // Neutral metadata only: no Title/Author/Subject/Keywords from the
        // source. Creation/modification dates, if written by Quartz, are the
        // export's own.
        let auxiliaryInfo = [kCGPDFContextCreator: RasterExporter.creator as NSString] as CFDictionary
        guard let pdfContext = CGContext(tempURL as CFURL, mediaBox: nil, auxiliaryInfo)
        else { throw ExportError.pdfWritingFailed }

        var pagePixelSizes: [CGSize] = []
        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex + 1),
                  let bitmap = PageBitmap(page: page, dpi: dpi) else {
                throw ExportError.pageRenderingFailed(pageIndex + 1)
            }
            let pixelRects = (redactions[pageIndex] ?? []).map { rect in
                // Expand by `padding` points in user space; the 90°-multiple
                // display transform keeps the expansion uniform.
                bitmap.pixelRect(forUserRect: rect.insetBy(dx: -padding, dy: -padding))
                    .intersection(bitmap.deviceBounds)
            }.filter { !$0.isNull && !$0.isEmpty }
            bitmap.blackOut(pixelRects)

            guard let image = bitmap.image else {
                throw ExportError.pageRenderingFailed(pageIndex + 1)
            }
            // New page in displayed size and orientation (rotation baked
            // into the pixels, no /Rotate entry needed). kCGPDFContextMediaBox
            // expects CFData containing the CGRect by value.
            let box = CGRect(origin: .zero, size: bitmap.geometry.displayedSize)
            let boxData = withUnsafeBytes(of: box) { Data($0) } as CFData
            pdfContext.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            pdfContext.draw(image, in: box)
            pdfContext.endPDFPage()
            pagePixelSizes.append(CGSize(width: bitmap.width, height: bitmap.height))
        }
        pdfContext.closePDF()

        let sha256 = try SHA256Hex.of(fileAt: tempURL)
        let fileSize = (try? fileManager.attributesOfItem(atPath: tempURL.path))?[.size] as? Int ?? 0

        // Atomic move within the destination directory.
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL, options: [])
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
        tempStillExists = false

        // C02: the original must be untouched.
        let originalHashAfter = try SHA256Hex.of(fileAt: original)
        guard originalHashAfter == originalHashBefore else {
            try? fileManager.removeItem(at: destination)
            throw ExportError.originalChangedDuringExport
        }

        return ExportOutcome(
            url: destination,
            sha256: sha256,
            pageCount: pageCount,
            pagePixelSizes: pagePixelSizes,
            dpi: dpi,
            fileSizeBytes: fileSize
        )
    }
}
