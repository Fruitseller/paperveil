import Foundation
import PaperVeilCore

/// Whitespace-tolerant verbatim matching of LLM quotes against the extracted
/// page text, with an index map back into the original `PageText.text` so that
/// findings get their geometry via `PageText.rects(for:)`.
///
/// Matching rules (applied identically to page and quote):
/// - any whitespace run (spaces, line breaks, tabs) collapses to a single space,
///   so a quote spanning a line break matches the page text;
/// - a hyphen directly followed by whitespace (hyphenated line break, e.g.
///   `Muster-\nstraße`) is dropped, so `Musterstraße` matches `Muster-\nstraße`.
/// Everything else must match character-for-character: the LLM is instructed
/// to quote verbatim, and any candidate that cannot be located is treated as
/// fabricated (`llmFabricatedQuote`) rather than redacted blindly.
enum LMStudioTextMatcher {
    /// An occurrence of a quote in a page's normalized text.
    enum Occurrence {
        case clean(NSRange)      // word-bounded, safe to redact
        case embedded(NSRange)   // only occurs inside a larger word → ambiguous
    }

    // MARK: Normalization

    /// Normalized text plus, for every normalized character, its UTF-16 offset
    /// in the original page text.
    private struct Normalized {
        let characters: [Character]
        let originalOffsets: [Int] // parallel to `characters`
        let totalUTF16: Int

        init(_ text: String) {
            let chars = Array(text)
            var prefix = [Int](repeating: 0, count: chars.count + 1)
            for (i, c) in chars.enumerated() { prefix[i + 1] = prefix[i] + c.utf16.count }
            var out: [Character] = []
            var offsets: [Int] = []
            var i = 0
            while i < chars.count {
                if chars[i].isWhitespace {
                    let runStart = i
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    out.append(" ")
                    offsets.append(prefix[runStart])
                } else if chars[i] == "-", i + 1 < chars.count, chars[i + 1].isWhitespace {
                    // Hyphenated line break: drop the hyphen and the following
                    // whitespace run; no separator is emitted.
                    i += 1
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                } else {
                    out.append(chars[i])
                    offsets.append(prefix[i])
                    i += 1
                }
            }
            self.characters = out
            self.originalOffsets = offsets
            self.totalUTF16 = prefix[chars.count]
        }

        func originalRange(ofNormalized range: Range<Int>) -> NSRange {
            let start = originalOffsets[range.lowerBound]
            let end = range.upperBound < originalOffsets.count ? originalOffsets[range.upperBound] : totalUTF16
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    // MARK: Matching

    /// All occurrences of `quote` in `page`. Whitespace-normalized, verbatim
    /// (no case folding, no umlaut rewriting), repeated occurrences included.
    static func occurrences(of quote: String, in page: PageText) -> [Occurrence] {
        var needle = Normalized(quote).characters
        while needle.first == " " { needle.removeFirst() }
        while needle.last == " " { needle.removeLast() }
        guard !needle.isEmpty else { return [] }
        let hay = Normalized(page.text)
        let n = hay.characters.count
        let m = needle.count
        guard m <= n else { return [] }
        var result: [Occurrence] = []
        var i = 0
        while i + m <= n {
            var equal = true
            for j in 0 ..< m where hay.characters[i + j] != needle[j] { equal = false; break }
            if equal {
                let cleanLeft = i == 0 || !isWordCharacter(hay.characters[i - 1])
                let cleanRight = i + m == n || !isWordCharacter(hay.characters[i + m])
                let range = hay.originalRange(ofNormalized: i ..< (i + m))
                result.append((cleanLeft && cleanRight) ? .clean(range) : .embedded(range))
                i += m
            } else {
                i += 1
            }
        }
        return result
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
