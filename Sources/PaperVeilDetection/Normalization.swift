import Foundation

/// Shared text normalization used by both the blocklist and the rule detector.
///
/// Matching never runs on the raw extracted page text. Instead every page text
/// is normalized once, and needles (blocklist values/variants, rule context
/// literals) are normalized the same way:
///
/// - lowercased,
/// - German umlaut transliteration expanded (`ä`→`ae`, `ö`→`oe`, `ü`→`ue`,
///   `ß`→`ss`), so "Müller" and "Mueller" become identical in both directions,
/// - every whitespace character mapped to a canonical one: newline-ish
///   characters to "\n", all other whitespace to " " (so identifiers broken
///   across lines still match, while rules that must not capture across a line
///   break can require a plain space),
/// - a hyphen directly followed by whitespace (a line-break hyphen) is removed
///   together with the following whitespace run, so "Muster-\nmann" normalizes
///   to "mustermann". A deliberate hyphen inside a word ("E-Mail", "A123-456")
///   survives because a letter follows it.
///
/// Every character of the normalized string keeps a mapping back to its UTF-16
/// position in the original page text, which is how match ranges become
/// `PageText.rects(for:)` geometry.
public struct NormalizedText: Sendable {
    /// The unmodified input text.
    public let original: String
    /// The normalized form that matching runs on.
    public let normalized: String
    /// UTF-16 offset into `original` for every UTF-16 unit of `normalized`.
    let sourceOffsets: [Int]
    /// UTF-16 length of the source character for every unit of `normalized`.
    let sourceLengths: [Int]

    /// Maps a UTF-16 range of the normalized string back into `original`.
    public func originalRange(forNormalizedUTF16Range range: NSRange) -> NSRange? {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= sourceOffsets.count
        else { return nil }
        let first = sourceOffsets[range.location]
        let lastIndex = range.location + range.length - 1
        let lastEnd = sourceOffsets[lastIndex] + sourceLengths[lastIndex]
        return NSRange(location: first, length: lastEnd - first)
    }

    /// Whether the original text has an uppercase letter at a given UTF-16
    /// offset. Normalization lowercases, so case-sensitive checks (e.g. the
    /// "PLZ Ort" rule) consult the original through this helper.
    public func isUppercaseLetterInOriginal(atUTF16Offset offset: Int) -> Bool {
        let nsOriginal = original as NSString
        guard offset >= 0, offset < nsOriginal.length else { return false }
        let character = nsOriginal.substring(with: NSRange(location: offset, length: 1))
        return character.first?.isUppercase == true
    }
}

public enum Normalization {
    /// Hyphen characters treated as a line-break hyphen when directly followed
    /// by whitespace: regular hyphen-minus, soft hyphen, and the common
    /// typographic hyphens.
    private static let lineBreakHyphens: Set<Character> = ["-", "\u{00AD}", "\u{2010}", "\u{2011}"]

    /// Expands German umlaut transliteration in a lowercased string.
    public static func expandUmlauts(_ string: String) -> String {
        string
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
    }

    /// Normalizes a needle (blocklist value/variant or rule context literal):
    /// lowercased, umlauts expanded, whitespace runs collapsed to single
    /// spaces, trimmed.
    public static func normalizeNeedle(_ needle: String) -> String {
        expandUmlauts(needle.lowercased())
            .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Normalizes a page text and remembers the mapping back to the original.
    public static func normalize(_ text: String) -> NormalizedText {
        let characters = Array(text)
        var utf16OffsetOf: [Int] = []
        utf16OffsetOf.reserveCapacity(characters.count)
        var running = 0
        for character in characters {
            utf16OffsetOf.append(running)
            running += character.utf16.count
        }

        var normalized = ""
        var sourceOffsets: [Int] = []
        var sourceLengths: [Int] = []
        normalized.reserveCapacity(running)
        sourceOffsets.reserveCapacity(running)
        sourceLengths.reserveCapacity(running)

        var i = 0
        while i < characters.count {
            let character = characters[i]
            if lineBreakHyphens.contains(character),
               i + 1 < characters.count,
               characters[i + 1].isWhitespace {
                // Line-break hyphen: drop the hyphen and the whitespace run
                // that follows, gluing the word together.
                i += 1
                while i < characters.count, characters[i].isWhitespace { i += 1 }
                continue
            }
            let offset = utf16OffsetOf[i]
            let length = character.utf16.count
            let piece: String
            if character.isWhitespace {
                piece = character.isNewline ? "\n" : " "
            } else {
                piece = expandUmlauts(character.lowercased())
            }
            for pieceCharacter in piece {
                normalized.append(pieceCharacter)
                for _ in 0..<pieceCharacter.utf16.count {
                    sourceOffsets.append(offset)
                    sourceLengths.append(length)
                }
            }
            i += 1
        }
        return NormalizedText(original: text,
                              normalized: normalized,
                              sourceOffsets: sourceOffsets,
                              sourceLengths: sourceLengths)
    }
}
