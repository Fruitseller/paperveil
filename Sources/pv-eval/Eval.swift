import CoreGraphics
import Foundation
import PaperVeilCore

extension Duration {
    /// Total duration in seconds (for latency reports).
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e9
    }
}


// MARK: - Normalisation helpers

/// Lowercased, all whitespace runs collapsed to single spaces, trimmed.
func EvalWhitespaceNormalized(_ s: String) -> String {
    s.lowercased()
        .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

func EvalDigitsOnly(_ s: String) -> String {
    String(s.filter(\.isNumber))
}

/// Whether the digits-only fallback applies to this needle: only for
/// "number-like" identifiers (mostly digits, at least 4 of them), so that
/// names or addresses with a stray digit never produce trivial digit matches.
func EvalDigitsFallbackApplies(_ needle: String) -> Bool {
    let letters = needle.filter(\.isLetter).count
    let digits = needle.filter(\.isNumber).count
    return digits >= 4 && letters <= 2
}

/// Strict-ish containment: whitespace/case-normalised substring, plus the
/// digits-only form for number-like needles.
func EvalContainsNormalized(_ needle: String, in haystack: String) -> Bool {
    let n = EvalWhitespaceNormalized(needle)
    let h = EvalWhitespaceNormalized(haystack)
    if n.count >= 3, h.contains(n) { return true }
    if EvalDigitsFallbackApplies(needle) {
        let nd = EvalDigitsOnly(needle)
        let hd = EvalDigitsOnly(haystack)
        if nd.count >= 4, hd.contains(nd) { return true }
    }
    return false
}

/// OCR-tolerant containment for mustPreserve legibility evidence: letters and
/// digits are compared, every other character counts as a word separator.
/// A dash variant (`-` vs `–`) or a decimal separator OCR quirk therefore
/// does not fail an otherwise legible value.
func EvalContainsLoose(_ needle: String, in haystack: String) -> Bool {
    if EvalContainsNormalized(needle, in: haystack) { return true }
    return EvalLooseNormalized(needle).count >= 3 && EvalLooseNormalized(haystack).contains(EvalLooseNormalized(needle))
}

/// Near-match tier for deliberately degraded scans: tolerates a small number
/// of OCR letter errors (e.g. »mellitus« read as »melitus«), but only when
/// every digit of the needle still appears in order – clinical numbers can
/// never be "fuzzy-read" into legibility.
func EvalContainsNear(_ needle: String, in haystack: String) -> Bool {
    let needleDigits = EvalDigitsOnly(needle)
    if !needleDigits.isEmpty {
        guard EvalDigitsOnly(haystack).contains(needleDigits) else { return false }
    }
    let needleLetters = EvalLettersOnly(needle)
    let haystackLetters = EvalLettersOnly(haystack)
    let n = Array(needleLetters)
    guard n.count >= 5 else { return false }
    if haystackLetters.contains(needleLetters) { return true }
    let maxDistance = max(1, n.count / 8)
    let h = Array(haystackLetters)
    let minLength = max(1, n.count - maxDistance)
    let maxLength = min(h.count, n.count + maxDistance)
    var start = 0
    while start + minLength <= h.count {
        for length in minLength...maxLength where start + length <= h.count {
            let window = h[start..<(start + length)]
            if levenshtein(n, Array(window)) <= maxDistance { return true }
        }
        start += 1
    }
    return false
}

private func EvalLooseNormalized(_ s: String) -> String {
    let mapped = s.lowercased().unicodeScalars.map { scalar -> String in
        CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
    }.joined()
    return mapped
        .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

private func EvalLettersOnly(_ s: String) -> String {
    s.lowercased()
        .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .filter(\.isLetter)
}

/// Levenshtein edit distance between two character arrays (small inputs).
private func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, substitution)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

/// Any positive-area intersection (used for clinical-content overlap, where
/// even a partial redaction destroys the value).
func EvalAnyOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
    let intersection = a.intersection(b)
    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
}

/// Whitespace-normalised, case-insensitive search of `needle` in the page
/// text; returns the covering rects (one union rect per line).
func EvalPageRects(of needle: String, in page: PageText) -> [PageRect]? {
    let chars = Array(page.text)
    guard !chars.isEmpty else { return nil }
    var prefix = [Int](repeating: 0, count: chars.count + 1)
    for (i, c) in chars.enumerated() { prefix[i + 1] = prefix[i] + c.utf16.count }

    var haystack: [Character] = []
    var haystackOffsets: [Int] = []
    var i = 0
    while i < chars.count {
        if chars[i].isWhitespace {
            let runStart = i
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if runStart > 0 {
                haystack.append(" ")
                haystackOffsets.append(prefix[runStart])
            }
        } else {
            haystack.append(chars[i].lowercased().first ?? chars[i])
            haystackOffsets.append(prefix[i])
            i += 1
        }
    }

    let needleChars = Array(EvalWhitespaceNormalized(needle))
    let m = needleChars.count
    guard m >= 1, haystack.count >= m else { return nil }

    var start = 0
    while start + m <= haystack.count {
        var equal = true
        for j in 0..<m where haystack[start + j] != needleChars[j] { equal = false; break }
        if equal {
            let location = haystackOffsets[start]
            let end = start + m < haystackOffsets.count ? haystackOffsets[start + m] : prefix[chars.count]
            let range = NSRange(location: location, length: max(0, end - location))
            guard range.length > 0 else { return nil }
            return page.rects(for: range)
        }
        start += 1
    }
    return nil
}

// MARK: - Report data model

struct FindingSnapshot: Codable, Sendable {
    var page: Int
    var category: String
    var origin: String
    var text: String

    init(_ finding: Finding) {
        page = finding.pageIndex
        category = finding.category.rawValue
        origin = finding.origin.rawValue
        text = finding.text
    }
}

struct FNItem: Codable, Sendable {
    var id: String
    var page: Int
    var category: String
    var text: String
    var expectOCRUncertain: Bool
    var expectedMappingProblem: Bool
}

struct ClinicalHit: Codable, Sendable {
    var finding: FindingSnapshot
    var mustPreserveText: String
    var mustPreserveNote: String?
    var page: Int
}

struct MethodReport: Codable, Sendable {
    /// blocklist | rules | combined | llm | combined_llm
    var key: String
    var displayName: String
    var findingCount: Int
    var tpIDs: [String]
    var fnItems: [FNItem]
    var fpItems: [FindingSnapshot]
    /// Findings that overlap a hidden or manualOnly annotation (not detection
    /// targets; hidden channels are covered by the export, C04).
    var hiddenHits: [FindingSnapshot]
    var clinicalHits: [ClinicalHit]
}

struct LocatedMustPreserve: Sendable {
    var item: FixtureMustPreserve
    var rects: [PageRect]
    var located: Bool
}

/// Evaluates one detection method's findings against a document's annotations.
///
/// Assignment per finding: first by meaningful rect overlap (best fraction
/// wins; visible targets take priority over hidden/manual annotations), then
/// by whitespace-normalised text match on the same page as a fallback.
/// Findings that match nothing annotated are false positives.
func evaluateMethod(key: String, displayName: String, findings: [Finding],
                    document: FixtureDocument,
                    mustPreserve: [LocatedMustPreserve]) -> MethodReport {
    var matchedVisible = Set<String>()
    var hiddenHits: [FindingSnapshot] = []
    var fpItems: [FindingSnapshot] = []

    for finding in findings {
        var bestVisible: (id: String, fraction: Double)?
        var bestHidden: (id: String, fraction: Double)?
        for annotation in document.identifiers where annotation.pageIndex == finding.pageIndex {
            guard let fraction = EvalRectOverlapFraction(finding: finding, annotation: annotation)
            else { continue }
            if annotation.isVisibleTarget {
                if bestVisible == nil || fraction > bestVisible!.fraction {
                    bestVisible = (annotation.id, fraction)
                }
            } else if bestHidden == nil || fraction > bestHidden!.fraction {
                bestHidden = (annotation.id, fraction)
            }
        }
        if let visible = bestVisible {
            matchedVisible.insert(visible.id)
            continue
        }
        if bestHidden != nil {
            hiddenHits.append(FindingSnapshot(finding))
            continue
        }
        // Text-match fallback on the same page.
        if let annotation = document.identifiers.first(where: {
            EvalTextMatches(finding: finding, annotation: $0)
        }) {
            if annotation.isVisibleTarget {
                matchedVisible.insert(annotation.id)
            } else {
                hiddenHits.append(FindingSnapshot(finding))
            }
            continue
        }
        fpItems.append(FindingSnapshot(finding))
    }

    let fnItems = document.identifiers
        .filter { $0.isVisibleTarget && !matchedVisible.contains($0.id) }
        .map { a in
            FNItem(id: a.id, page: a.pageIndex, category: a.category, text: a.text,
                   expectOCRUncertain: a.expectOCRUncertain,
                   expectedMappingProblem: a.expectedMappingProblem)
        }

    var clinicalHits: [ClinicalHit] = []
    for located in mustPreserve where located.located {
        for finding in findings where finding.pageIndex == located.item.pageIndex {
            let overlaps = finding.rects.contains { findingRect in
                located.rects.contains { EvalAnyOverlap(findingRect.cgRect, $0.cgRect) }
            }
            if overlaps {
                clinicalHits.append(ClinicalHit(
                    finding: FindingSnapshot(finding),
                    mustPreserveText: located.item.text,
                    mustPreserveNote: located.item.note,
                    page: finding.pageIndex
                ))
            }
        }
    }

    return MethodReport(key: key, displayName: displayName, findingCount: findings.count,
                        tpIDs: document.identifiers.filter { matchedVisible.contains($0.id) }.map(\.id),
                        fnItems: fnItems, fpItems: fpItems, hiddenHits: hiddenHits,
                        clinicalHits: clinicalHits)
}

// MARK: - Bounded-concurrency map

/// Runs `transform` over `items` with at most `limit` tasks in flight and
/// returns the results in the original order. Failures are not expected here:
/// per-document errors are captured inside the transform.
func mapWithLimit<Input: Sendable, Output: Sendable>(
    items: [Input], limit: Int,
    _ transform: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    precondition(limit >= 1)
    var results: [Output?] = .init(repeating: nil, count: items.count)
    let indexed = Array(items.enumerated())
    await withTaskGroup(of: (Int, Output).self) { group in
        var iterator = indexed.makeIterator()
        var inFlight = 0
        while inFlight < limit, let (index, item) = iterator.next() {
            group.addTask { (index, await transform(item)) }
            inFlight += 1
        }
        while let (index, output) = await group.next() {
            results[index] = output
            inFlight -= 1
            if let (index, item) = iterator.next() {
                group.addTask { (index, await transform(item)) }
                inFlight += 1
            }
        }
    }
    return results.compactMap { $0 }
}

/// Path relative to the current directory when possible, so public reports carry no local home paths.
func EvalDisplayPath(_ url: URL) -> String {
    let cwd = FileManager.default.currentDirectoryPath + "/"
    let p = url.standardizedFileURL.path
    return p.hasPrefix(cwd) ? String(p.dropFirst(cwd.count)) : url.lastPathComponent
}
