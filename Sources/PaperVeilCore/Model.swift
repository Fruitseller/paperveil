import CoreGraphics
import CryptoKit
import Foundation

/// Neutral document identifier. Never derived from the original file name.
public struct DocumentID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> DocumentID {
        DocumentID(rawValue: "PV-" + UUID().uuidString.prefix(8).uppercased())
    }
    public var description: String { rawValue }
}

/// Axis-aligned rectangle in PDF *page space* (points, origin bottom-left of the
/// page's unrotated media box), i.e. the coordinate system of `PDFPage.bounds(for: .mediaBox)`.
public struct PageRect: Hashable, Codable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ r: CGRect) { self.init(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func union(_ o: PageRect) -> PageRect { PageRect(cgRect.union(o.cgRect)) }
    public func intersects(_ o: PageRect) -> Bool { cgRect.intersects(o.cgRect) }
}

public enum IdentifierCategory: String, Codable, Sendable, CaseIterable {
    case name, address, birthDate, phone, email, insuranceNumber, patientID, other, image
}

public enum FindingOrigin: String, Codable, Sendable, CaseIterable {
    case blocklist, rule, llm, manual
}

public enum FindingDecision: String, Codable, Sendable {
    case proposed, accepted, rejected
}

/// Where text came from. OCR text is derived and never treated as verified original.
public enum TextSource: String, Codable, Sendable { case pdfText, ocr }

public struct Finding: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var documentID: DocumentID
    public var pageIndex: Int
    /// One or more rects (e.g. identifier broken across lines).
    public var rects: [PageRect]
    /// Matched text as present in the extracted page text (empty for manual area marks).
    public var text: String
    public var category: IdentifierCategory
    public var origin: FindingOrigin
    public var decision: FindingDecision
    public var note: String?

    public init(id: UUID = UUID(), documentID: DocumentID, pageIndex: Int, rects: [PageRect], text: String,
                category: IdentifierCategory, origin: FindingOrigin, decision: FindingDecision = .proposed,
                note: String? = nil) {
        self.id = id; self.documentID = documentID; self.pageIndex = pageIndex; self.rects = rects
        self.text = text; self.category = category; self.origin = origin; self.decision = decision; self.note = note
    }

    /// Findings that are blacked out in the export: everything not explicitly rejected.
    public var isRedacted: Bool { decision != .rejected }
}

public enum WarningKind: String, Codable, Sendable {
    case llmUnavailable, llmInvalidResponse, llmFabricatedQuote, llmAmbiguousMatch, llmTimeout
    case lowOCRConfidence, ocrOnlyPage, exportValidationFailed, inputProblem
}

/// A warning blocks approval until the user explicitly acknowledges it.
public struct ProcessingWarning: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: WarningKind
    public var pageIndex: Int?
    public var message: String
    public var acknowledged: Bool
    public init(id: UUID = UUID(), kind: WarningKind, pageIndex: Int? = nil, message: String, acknowledged: Bool = false) {
        self.id = id; self.kind = kind; self.pageIndex = pageIndex; self.message = message; self.acknowledged = acknowledged
    }
}

public enum SHA256Hex {
    public static func of(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func of(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
