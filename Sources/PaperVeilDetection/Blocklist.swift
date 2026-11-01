import Foundation
import PaperVeilCore

/// The user's personal blocklist (Sperrliste): identifiers that must always be
/// found when they appear in a document.
///
/// Entries are stored as JSON (`{"entries": [...]}`, load also accepts a bare
/// `[...]` array) and matched together with their documented variants
/// automatically:
///
/// - case-insensitive,
/// - arbitrary whitespace or line breaks between tokens,
/// - line-break hyphens ("Muster-\nmann" matches "Mustermann"),
/// - umlaut transliteration ("Müller" matches "Mueller" and vice versa),
/// - names of the form "Vorname Nachname" also match "Nachname, Vorname" and
///   the initial form "M. Nachname",
/// - needles containing digits are treated as identifiers: spaces, dots,
///   slashes and hyphens between the characters are ignored
///   ("A123 456 789" matches "A123456789").
///
/// Matching is whole-word only; an identifier inside a longer word is not
/// flagged. Every occurrence — including repeats on the same page — becomes
/// its own finding with origin `.blocklist` and decision `.proposed`.
public struct Blocklist: Codable, Equatable, Hashable, Sendable {
    /// One blocklist line: an identifier, its category and optional explicit
    /// additional spellings.
    public struct Entry: Codable, Hashable, Sendable {
        /// The identifier as maintained by the user, e.g. "Erika Mustermann"
        /// or "A123456789".
        public var value: String
        public var category: IdentifierCategory
        /// Additional explicit spellings; matched with the same automatic
        /// variant logic as `value`.
        public var variants: [String]

        public init(value: String, category: IdentifierCategory, variants: [String] = []) {
            self.value = value
            self.category = category
            self.variants = variants
        }

        private enum CodingKeys: String, CodingKey { case value, category, variants }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(String.self, forKey: .value)
            category = try container.decodeIfPresent(IdentifierCategory.self, forKey: .category) ?? .other
            variants = try container.decodeIfPresent([String].self, forKey: .variants) ?? []
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: - Persistence

    /// Loads a blocklist from a JSON file. Accepts both the canonical
    /// `{"entries": [...]}` object and a bare `[...]` array; `variants` and
    /// `category` may be omitted per entry.
    public static func load(from url: URL) throws -> Blocklist {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Blocklist.self, from: data)
    }

    /// Writes the blocklist as pretty-printed JSON, atomically.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Detection

    /// Finds every occurrence of every entry (value and explicit variants,
    /// plus the automatic variants documented on the type) on all pages.
    public func detect(in pages: [PageText], documentID: DocumentID) -> [Finding] {
        // Compile one matcher per distinct needle, reused across all pages.
        var cache: [String: NSRegularExpression?] = [:]
        var matchers: [(regex: NSRegularExpression, category: IdentifierCategory, entry: Int)] = []
        for (index, entry) in entries.enumerated() {
            for needle in [entry.value] + entry.variants {
                let normalized = Normalization.normalizeNeedle(needle)
                guard !normalized.isEmpty else { continue }
                if !cache.keys.contains(normalized) {
                    cache[normalized] = Self.pattern(forNormalizedNeedle: normalized)
                }
                if let regex = cache[normalized] ?? nil {
                    matchers.append((regex, entry.category, index))
                }
            }
        }
        guard !matchers.isEmpty else { return [] }

        var findings: [Finding] = []
        for page in pages {
            let normalized = Normalization.normalize(page.text)
            let nsNormalized = normalized.normalized as NSString
            var pageFindings: [(location: Int, finding: Finding)] = []
            var seen = Set<String>()
            for matcher in matchers {
                let matches = matcher.regex.matches(
                    in: normalized.normalized,
                    options: [],
                    range: NSRange(location: 0, length: nsNormalized.length)
                )
                for match in matches {
                    guard let originalRange = normalized.originalRange(forNormalizedUTF16Range: match.range)
                    else { continue }
                    let key = "\(matcher.entry)|\(originalRange.location)|\(originalRange.length)"
                    guard seen.insert(key).inserted else { continue }
                    let text = (page.text as NSString).substring(with: originalRange)
                    pageFindings.append((originalRange.location,
                        Finding(documentID: documentID,
                                pageIndex: page.pageIndex,
                                rects: page.rects(for: originalRange),
                                text: text,
                                category: matcher.category,
                                origin: .blocklist)))
                }
            }
            pageFindings.sort { $0.location < $1.location }
            findings.append(contentsOf: pageFindings.map(\.finding))
        }
        return findings
    }

    // MARK: - Pattern construction

    /// Builds a whole-word regex for an already normalized needle.
    ///
    /// A needle containing a digit is treated as an identifier: spaces, dots,
    /// slashes and hyphens between the characters are ignored. Otherwise it
    /// is treated as a name/phrase: tokens are separated by whitespace, and a
    /// two-token name additionally matches the reversed ("Nachname, Vorname")
    /// and initial ("M. Nachname") forms. Whole-word boundaries are expressed
    /// as lookarounds (not `\b`) so needles ending in punctuation still match.
    static func pattern(forNormalizedNeedle needle: String) -> NSRegularExpression? {
        if needle.contains(where: \.isNumber) {
            // Identifier semantics: ignore separators between the characters.
            let significant = needle.filter { $0.isLetter || $0.isNumber || $0 == "+" }
            guard !significant.isEmpty else { return nil }
            let pattern = "(?<![0-9\\p{L}+])"
                + significant.map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "[\\s./\\-]*")
                + "(?![0-9\\p{L}])"
            return try? NSRegularExpression(pattern: pattern)
        }

        let tokens = needle.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }
        func escaped(_ token: String) -> String {
            NSRegularExpression.escapedPattern(for: token)
        }
        if tokens.count == 2, tokens.allSatisfy({ $0.first?.isLetter == true }) {
            let first = escaped(tokens[0])
            let last = escaped(tokens[1])
            let initial = escaped(String(tokens[0].prefix(1)))
            let pattern = "(?<![0-9\\p{L}])(?:\(first)\\s+\(last)"
                + "|\(last)\\s*,\\s*\(first)"
                + "|\(initial)\\.\\s*\(last))(?![0-9\\p{L}])"
            return try? NSRegularExpression(pattern: pattern)
        }
        let pattern = "(?<![0-9\\p{L}])"
            + tokens.map(escaped).joined(separator: "\\s+")
            + "(?![0-9\\p{L}])"
        return try? NSRegularExpression(pattern: pattern)
    }

    // MARK: - Codable (object form, tolerant of a bare array)

    private struct Keyed: Codable, Sendable {
        let entries: [Entry]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let keyed = try? container.decode(Keyed.self) {
            entries = keyed.entries
        } else {
            entries = try container.decode([Entry].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Keyed(entries: entries))
    }
}
