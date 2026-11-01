import Foundation
import PDFKit
import PaperVeilCore

/// A PDF that passed input validation. The document is opened for reading only;
/// the original file is never modified by extraction.
public struct ValidatedPDF {
    /// Original file URL (read-only use only).
    public let url: URL
    /// The loaded document. `PDFDocument` is not `Sendable`; keep it on the task
    /// that performs the extraction and do not hand it across actor boundaries.
    public let document: PDFDocument
    public let pageCount: Int
}

/// Why an input file cannot be processed. All messages are user-facing German.
public enum InputError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The file is missing, moved or not readable with the current permissions.
    case unreadableFile
    /// Magic bytes (`%PDF-`) are absent — not a PDF at all.
    case notAPDF
    /// The PDF cannot be parsed (damaged, incomplete or otherwise unusable).
    case damagedOrUnparseable
    /// Structurally valid PDF without any page.
    case zeroPages
    /// Password-protected; PaperVeil never attempts to unlock.
    case encryptedOrLocked

    public var description: String {
        switch self {
        case .unreadableFile:
            "Die Datei konnte nicht gelesen werden. Sie fehlt, wurde verschoben oder der Lesezugriff fehlt."
        case .notAPDF:
            "Diese Datei ist kein PDF."
        case .damagedOrUnparseable:
            "Die PDF-Datei ist beschädigt oder konnte nicht gelesen werden."
        case .zeroPages:
            "Die PDF-Datei enthält keine Seiten."
        case .encryptedOrLocked:
            "Die PDF-Datei ist verschlüsselt oder durch ein Passwort geschützt. Verschlüsselte Dateien werden von PaperVeil nicht geöffnet."
        }
    }

    public var errorDescription: String? { description }
}

public enum InputValidator {
    /// Maximum number of bytes inspected to distinguish an empty (zero-page)
    /// PDF from a damaged one when PDFKit refuses to open the file.
    private static let structuralInspectionLimit = 32 * 1024 * 1024
    /// A document is considered pageless only if its tail carries a valid EOF marker.
    private static let eofSearchWindow = 1024

    /// Validates a PDF file for processing. Opens the file strictly read-only and
    /// never modifies it. Encrypted/locked documents are rejected without any
    /// attempt to unlock them.
    public static func validate(url: URL) throws -> ValidatedPDF {
        // 1. Readable, existing file.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw InputError.unreadableFile
        }
        let header = try readHeader(url: url)

        // 2. Magic bytes. We tolerate a limited amount of leading garbage
        //    (as produced by some PDF writers) but require `%PDF-` near the start.
        guard header.containsMagicPDF else {
            throw InputError.notAPDF
        }

        // 3. PDFKit must be able to load the document.
        guard let document = PDFDocument(url: url) else {
            // PDFKit (and CoreGraphics) refuse to open zero-page PDFs altogether,
            // so a valid PDF skeleton without any page object is reported as
            // "zero pages" instead of "damaged".
            if looksLikePagelessPDF(url: url) { throw InputError.zeroPages }
            throw InputError.damagedOrUnparseable
        }

        // 4. Encrypted / locked (before any unlock attempt).
        if document.isEncrypted || document.isLocked {
            throw InputError.encryptedOrLocked
        }

        // 5. Defensive: a loaded document must have pages.
        guard document.pageCount > 0 else {
            throw InputError.zeroPages
        }

        return ValidatedPDF(url: url, document: document, pageCount: document.pageCount)
    }

    /// Reads the first 1024 bytes (or fewer for short files). A file that cannot
    /// be opened for reading at all is reported as unreadable.
    private static func readHeader(url: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return (try handle.read(upToCount: 1024)) ?? Data()
        } catch {
            throw InputError.unreadableFile
        }
    }

    /// Heuristic used when PDFKit refuses to load a file that starts with `%PDF`
    /// (both PDFKit and CoreGraphics reject zero-page PDFs outright): a
    /// structurally complete document (EOF marker at the tail) that contains no
    /// page object but positive evidence of an empty page tree (`/Count 0` or
    /// `/Kids []`) is a zero-page PDF; anything else is treated as damaged.
    /// Bounded to keep the cost of classifying broken inputs low.
    private static func looksLikePagelessPDF(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: structuralInspectionLimit), !data.isEmpty else { return false }

        // `%%EOF` must appear near the end of the file.
        let tailStart = data.endIndex >= data.startIndex + eofSearchWindow
            ? data.index(data.endIndex, offsetBy: -eofSearchWindow)
            : data.startIndex
        let eofMarker = Data("%%EOF".utf8)
        guard let tailRange = data.range(of: eofMarker, in: tailStart..<data.endIndex) else { return false }
        // The EOF marker must not be followed by substantial content.
        let rest = data.distance(from: tailRange.upperBound, to: data.endIndex)
        guard rest < 16 else { return false }

        // Any `/Type /Page` object (not `/Pages`) means the document does have pages.
        guard !containsPageObject(data) else { return false }
        // Positive evidence of an empty page tree. Without this, a damaged file
        // with compressed object streams (where `/Type /Page` is not visible as
        // plain bytes) would be misclassified as pageless.
        return containsEmptyPageTree(data)
    }

    /// Looks for `/Count 0` or an empty `/Kids []` in the raw bytes.
    private static func containsEmptyPageTree(_ data: Data) -> Bool {
        if data.range(of: Data("/Count 0".utf8)) != nil { return true }
        let kids = Data("/Kids".utf8)
        var cursor = data.startIndex
        while let kidsRange = data.range(of: kids, in: cursor..<data.endIndex) {
            var i = kidsRange.upperBound
            var skipped = 0
            while i < data.endIndex, skipped < 8, isPDFWhitespace(data[i]) {
                i = data.index(after: i)
                skipped += 1
            }
            if data.range(of: Data("[]".utf8), in: i..<data.endIndex)
                .map({ data.distance(from: i, to: $0.lowerBound) == 0 }) == true {
                return true
            }
            cursor = kidsRange.upperBound
        }
        return false
    }

    /// Scans raw bytes for a `/Type … /Page` object entry, ignoring `/Pages`.
    private static func containsPageObject(_ data: Data) -> Bool {
        let type = Data("/Type".utf8)
        let page = Data("/Page".utf8)
        var cursor = data.startIndex
        while let typeRange = data.range(of: type, in: cursor..<data.endIndex) {
            var i = typeRange.upperBound
            // Skip at most a little whitespace between `/Type` and the value.
            var skipped = 0
            while i < data.endIndex, skipped < 32, isPDFWhitespace(data[i]) {
                i = data.index(after: i)
                skipped += 1
            }
            if let pageRange = data.range(of: page, in: i..<data.endIndex),
               data.distance(from: i, to: pageRange.lowerBound) == 0 {
                let after = pageRange.upperBound
                // `/Pages` (and friends like `/PageMode`) are not page objects.
                let next: UInt8? = after < data.endIndex ? data[after] : nil
                if next != UInt8(ascii: "s") && next != UInt8(ascii: "M") && next != UInt8(ascii: "L") {
                    return true
                }
            }
            cursor = typeRange.upperBound
        }
        return false
    }

    private static func isPDFWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C || byte == 0x00
    }
}

private extension Data {
    var containsMagicPDF: Bool {
        let magic = Data("%PDF-".utf8)
        // PDF magic must be within the first 1024 bytes.
        let window = endIndex >= startIndex + 1024 ? index(startIndex, offsetBy: 1024) : endIndex
        return range(of: magic, in: startIndex..<window) != nil
    }
}
