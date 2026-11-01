import Foundation
import PDFKit

/// Independent forensic survey of a PDF (for the CLI and for acceptance runs).
/// Everything is best-effort: when the raw structure cannot be fully parsed,
/// `structureParsingComplete` is false and `notes` says why. A report is data,
/// never a verdict.
public struct InspectionReport: Sendable {
    public let path: String
    public let pageCount: Int
    /// Text extracted by PDFKit (text layer; includes invisible text).
    public let extractedText: String
    /// Raw /Info dictionary keys and values.
    public let infoDictionary: [String: String]
    /// Raw catalog keys (without leading slash).
    public let catalogKeys: [String]
    public let annotationCount: Int
    public let hasEmbeddedFiles: Bool
    public let hasForm: Bool
    public let hasOutlines: Bool
    public let hasOpenAction: Bool
    public let isEncrypted: Bool
    /// Image XObjects per page, in page order.
    public let perPageImageCount: [Int]
    public let structureParsingComplete: Bool
    public let notes: [String]

    public init(path: String, pageCount: Int, extractedText: String, infoDictionary: [String: String],
                catalogKeys: [String], annotationCount: Int, hasEmbeddedFiles: Bool, hasForm: Bool,
                hasOutlines: Bool, hasOpenAction: Bool, isEncrypted: Bool, perPageImageCount: [Int],
                structureParsingComplete: Bool, notes: [String]) {
        self.path = path
        self.pageCount = pageCount
        self.extractedText = extractedText
        self.infoDictionary = infoDictionary
        self.catalogKeys = catalogKeys
        self.annotationCount = annotationCount
        self.hasEmbeddedFiles = hasEmbeddedFiles
        self.hasForm = hasForm
        self.hasOutlines = hasOutlines
        self.hasOpenAction = hasOpenAction
        self.isEncrypted = isEncrypted
        self.perPageImageCount = perPageImageCount
        self.structureParsingComplete = structureParsingComplete
        self.notes = notes
    }
}

/// Lists the side channels a document has: text layer, metadata, catalog
/// structure, annotations, embedded files, forms, images. Used to inspect
/// exports (must be empty of all of these except images) and, for
/// verification, originals.
public enum ExportInspector {
    public static func inspect(url: URL) -> InspectionReport {
        let structure = PDFStructure.parse(data: (try? Data(contentsOf: url)) ?? Data())
        let document = PDFDocument(url: url)
        let cgDocument = CGPDFDocument(url as CFURL)

        let pageCount = cgDocument?.numberOfPages ?? document?.pageCount ?? 0

        // Annotations: raw structure first; PDFKit as fallback when the raw
        // parse could not see the page tree.
        var annotationCount = structure.annotationCount
        var notes = structure.notes
        if !structure.parsingComplete, let document {
            var kitCount = 0
            for index in 0..<document.pageCount {
                kitCount += document.page(at: index)?.annotations.count ?? 0
            }
            annotationCount = kitCount
            notes.append("Seitenstruktur nicht im Rohformat lesbar; Annotationen via PDFKit ermittelt.")
        }

        let kitEncrypted = document?.isEncrypted ?? false
        let isEncrypted = kitEncrypted || structure.isEncrypted

        return InspectionReport(
            path: url.path,
            pageCount: pageCount,
            extractedText: document?.string ?? "",
            infoDictionary: structure.infoDictionary,
            catalogKeys: structure.catalogKeys,
            annotationCount: annotationCount,
            hasEmbeddedFiles: structure.hasEmbeddedFiles,
            hasForm: structure.hasForm,
            hasOutlines: structure.hasOutlines,
            hasOpenAction: structure.hasOpenAction,
            isEncrypted: isEncrypted,
            perPageImageCount: structure.perPageImageCount,
            structureParsingComplete: structure.parsingComplete,
            notes: notes
        )
    }
}
