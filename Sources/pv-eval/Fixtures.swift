import Foundation
import PaperVeilCore

// MARK: - Annotation schema (Fixtures/synthetic/annotations.json)
// Mirrors Sources/pv-fixtures/AnnotationModel.swift, which is not importable
// from here (separate executable target).

struct FixtureAnnotationFile: Codable, Sendable {
    var schemaVersion: Int
    var generator: String
    var contentDate: String
    var documents: [FixtureDocument]
}

struct FixtureDocument: Codable, Sendable {
    var file: String
    var kind: String
    var expectedInputOutcome: String
    var password: String?
    var pageCount: Int
    var pageRotations: [Int]
    var notes: String?
    var identifiers: [FixtureIdentifier]
    var mustPreserve: [FixtureMustPreserve]
}

struct FixtureIdentifier: Codable, Sendable {
    var id: String
    var pageIndex: Int
    var text: String
    var category: String
    var rects: [PageRect]
    var occurrence: Int?
    var hidden: Bool
    var channel: String?
    var manualOnly: Bool
    var expectOCRUncertain: Bool
    var expectedMappingProblem: Bool
    var note: String?

    /// Detection target: visible, text-bearing identifier.
    var isVisibleTarget: Bool { !hidden && !manualOnly }
}

struct FixtureMustPreserve: Codable, Sendable {
    var pageIndex: Int
    var text: String
    var rect: PageRect?
    var note: String?
}

enum FixtureLoadError: Error, CustomStringConvertible {
    case missingFile(URL)

    var description: String {
        switch self {
        case .missingFile(let url): "Datei nicht gefunden oder nicht lesbar: \(url.path)"
        }
    }
}

func loadFixtureAnnotations(dir: URL) throws -> FixtureAnnotationFile {
    let url = dir.appendingPathComponent("annotations.json")
    guard let data = try? Data(contentsOf: url) else { throw FixtureLoadError.missingFile(url) }
    do {
        return try JSONDecoder().decode(FixtureAnnotationFile.self, from: data)
    } catch {
        throw FixtureLoadError.missingFile(url)
    }
}

extension FixtureIdentifier {
    /// Loose hit test (rect overlap ≥30 % of an annotation rect OR
    /// whitespace-normalised text match on the same page). Used where a
    /// per-annotation "was it found" answer is enough (export review
    /// simulation).
    func isHit(by finding: Finding) -> Bool {
        finding.pageIndex == pageIndex
            && (EvalRectOverlapFraction(finding: finding, annotation: self) != nil
                || EvalTextMatches(finding: finding, annotation: self))
    }
}

/// Highest intersection fraction of any finding rect with any annotation rect,
/// relative to the annotation rect's area; nil when below the 30 % threshold.
func EvalRectOverlapFraction(finding: Finding, annotation: FixtureIdentifier) -> Double? {
    guard finding.pageIndex == annotation.pageIndex else { return nil }
    var best: Double = 0
    for findingRect in finding.rects {
        for annotationRect in annotation.rects {
            let intersection = findingRect.cgRect.intersection(annotationRect.cgRect)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
            let area = annotationRect.width * annotationRect.height
            guard area > 0 else { continue }
            let fraction = (intersection.width * intersection.height) / area
            if fraction > best { best = fraction }
        }
    }
    return best >= 0.3 ? best : nil
}

/// Whitespace-normalised text match on the same page (fallback when rects do
/// not overlap meaningfully, e.g. for channels without rects).
func EvalTextMatches(finding: Finding, annotation: FixtureIdentifier) -> Bool {
    guard finding.pageIndex == annotation.pageIndex else { return false }
    let findingText = EvalWhitespaceNormalized(finding.text)
    guard findingText.count >= 3 else { return false }
    let annotationText = EvalWhitespaceNormalized(annotation.text)
    return findingText == annotationText
        || annotationText.contains(findingText)
        || findingText.contains(annotationText)
}
