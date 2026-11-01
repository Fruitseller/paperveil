import Foundation
import PaperVeilCore

/// Words that must not be captured as a name after "Patient:", "Frau" & co.
private let nameStopwords: Set<String> = [
    "ich", "du", "sie", "er", "es", "wir", "ihr",
    "bitte", "kein", "keine", "keinen", "keinem", "nichts", "unbekannt",
    "folgt", "folgende", "folgenden", "weitere", "weiteren", "weiter",
    "bekannt", "heute", "gestern", "morgen", "ja", "nein",
    "diese", "dieser", "dieses", "jene",
    "dr", "prof", "med",
]

/// The built-in context rules. Each case knows its regex pattern, its finding
/// category, and whether it runs on the original text (needed for
/// capitalization) or on the normalized text.
private enum RuleID: CaseIterable, Sendable {
    /// E-mail address; no context needed.
    case email
    /// Phone/fax with an international prefix (+49 or 0049); no context needed.
    case phoneInternational
    /// 0-prefix phone/fax number behind a context word (see the pattern).
    case phoneContext
    /// Street name ending in a street suffix plus house number.
    case street
    /// "PLZ Ort": 5-digit postal code plus a capitalized city.
    case postalCode
    /// Birth date, only behind a birth context.
    case birthDate
    /// Structural German KVNR: one letter plus nine digits.
    case insuranceNumber
    /// Insurance number behind a context label.
    case insuranceContext
    /// Patient/case number behind a context label.
    case patientIDContext
    /// Name behind a salutation or label; runs on the original text.
    case nameContext

    var category: IdentifierCategory {
        switch self {
        case .email: .email
        case .phoneInternational, .phoneContext: .phone
        case .street, .postalCode: .address
        case .birthDate: .birthDate
        case .insuranceNumber, .insuranceContext: .insuranceNumber
        case .patientIDContext: .patientID
        case .nameContext: .name
        }
    }

    var runsOnOriginalText: Bool {
        self == .nameContext
    }

    /// Patterns run against the *normalized* page text (lowercase, umlauts
    /// expanded) — except `.nameContext`, which needs capitalization and runs
    /// against the original text. Group 1 (or the whole match) always spans
    /// exactly the identifier, never the context label.
    var pattern: String {
        switch self {
        case .email:
            "\\b([a-z0-9._%+\\-]+@[a-z0-9.\\-]+\\.[a-z]{2,})"
        case .phoneInternational:
            "(?<![0-9a-z])(\\+49[\\d ./()\\-]{4,24}\\d|0049[\\d ./()\\-]{4,24}\\d)"
        case .phoneContext:
            // Context words: Tel, Telefon(Nummer), Telefax, Fax(-Nr.), Mobil,
            // Handy — each optionally with "nummer"/"-nr."/"Nr.". The number
            // itself starts with 0, optionally in brackets; dots are
            // deliberately not allowed inside the number so clinical dates
            // and decimals cannot match.
            "(?<![a-z0-9])(?:telefon|telefax|mobil|handy|fax|tel)(?:nummer|-?nr)?\\.?\\s*(?:-?nr\\.?)?\\s*:?\\s*"
                + "(\\(?[\\s/()\\-]*0[\\d ./()\\-]{4,24}\\d\\)?)"
        case .street:
            // Street suffixes: straße, str., allee, gasse, damm (also bare) and
            // weg, platz, ring (prefix required, to avoid "Platz 4" ranking
            // false positives); followed by the house number. Line breaks are
            // allowed between street and number.
            "\\b((?:\\p{L}+)?(?:strasse|str\\.)|\\p{L}+(?:allee|gasse|damm|weg|platz|ring))\\s+(\\d{1,5}[a-z]?)\\b"
        case .postalCode:
            // "PLZ Ort": the PLZ and the city may be separated by a line
            // break; an optional second city word ("Bad Homburg") must be on
            // the same line as the first, so the rule never reaches into the
            // next line.
            "(?<![\\d.,])(\\d{5})(?!\\d)(\\s+\\p{L}{3,}(?:[ ]\\p{L}{3,})?)\\b"
        case .birthDate:
            // Contexts: Geburtsdatum, geboren, geb., Geb.-Dat. and a literal
            // asterisk; optional "am" in between. Formats: dd.mm.yyyy,
            // d.m.yy, dd.mm.yy. The year is deliberately not validated.
            "(?<![\\p{L}\\d])(?:geburtsdatum|geboren|geb\\.-dat\\.|geb\\.|\\*)\\s*:?\\s*(?:am\\s+)?"
                + "(\\d{1,2}\\.\\d{1,2}\\.(?:\\d{4}|\\d{2}))(?!\\d)"
        case .insuranceNumber:
            // German KVNR: one letter plus nine digits, single spaces or
            // hyphens between groups allowed.
            "(?<![0-9a-z])[a-z](?:[\\s\\-]?\\d){9}(?![0-9a-z])"
        case .insuranceContext:
            // Contexts: Versichertennr., Versicherten-Nr., Vers.-Nr., KV-Nr.
            // (also "KVNR"). The value is any 6–12 char alphanumeric token that
            // contains at least one digit.
            "(?<![a-z0-9])(?:versicherten-?nr|vers\\.?-?nr|kv-?nr)\\.?\\s*:?\\s*([a-z0-9]{6,12})(?![0-9a-z])"
        case .patientIDContext:
            // Contexts: Pat.-Nr., Patienten-ID, Fall-Nr., Aufnahme-Nr.
            // The value is any 3–12 char alphanumeric token (hyphens/slashes
            // inside allowed) that contains at least one digit.
            "(?<![a-z0-9])(?:pat\\.?-?nr|patienten-?id|fall-?nr|aufnahme-?nr)\\.?\\s*:?\\s*([a-z0-9][a-z0-9\\-/]{2,11})(?![0-9a-z])"
        case .nameContext:
            // Contexts: Patient, Patientin, Patientinnen, Name, Herr(n), Frau
            // (case-insensitive), optionally with a period/colon; up to two
            // "Dr./Prof. [med.]" titles are skipped but not captured. The name
            // is 1–3 capitalized words. Runs on the original text.
            "\\b(?i:patientinnen|patientin|patient|name|herrn?|frau)\\.?\\s*:?\\s*"
                + "(?:(?i:dr|prof)\\.\\s*(?:(?i:med)\\.\\s*)?){0,2}"
                + "(\\p{Lu}[\\p{L}\\-']*(?:\\s+\\p{Lu}[\\p{L}\\-']*){0,2})"
        }
    }
}

/// Context-based detection rules (Kontextregeln) for the identifier kinds that
/// follow reproducible patterns in German medical letters: e-mail, phone/fax
/// number, postal address, birth date, insurance number, patient/case numbers
/// and names after a salutation or label.
///
/// Only the identifier itself is flagged, never the context label. Clinical
/// content — lab values with decimal comma and minus, reference ranges,
/// dosages, plain clinical dates, ICD codes, physician titles — is deliberately
/// not matched. All findings have origin `.rule` and decision `.proposed`.
public struct RuleDetector: Sendable {

    public init() {}

    public func detect(in pages: [PageText], documentID: DocumentID) -> [Finding] {
        let regexes = Self.compileAll()
        var findings: [Finding] = []
        for page in pages {
            findings.append(contentsOf: detectOnPage(page, regexes: regexes, documentID: documentID))
        }
        return findings
    }

    // MARK: - Internals

    private func detectOnPage(_ page: PageText,
                               regexes: [RuleID: NSRegularExpression],
                               documentID: DocumentID) -> [Finding] {
        let normalized = Normalization.normalize(page.text)
        let nsOriginal = page.text as NSString
        let nsNormalized = normalized.normalized as NSString
        var pageFindings: [(location: Int, finding: Finding)] = []
        var seen = Set<String>()

        for rule in RuleID.allCases {
            guard let regex = regexes[rule] else { continue }
            let runsOnOriginal = rule.runsOnOriginalText
            let haystack: NSString = runsOnOriginal ? nsOriginal : nsNormalized
            let matches = regex.matches(in: haystack as String,
                                         options: [],
                                         range: NSRange(location: 0, length: haystack.length))
            for match in matches {
                guard let identifierRange = originalIdentifierRange(for: match, rule: rule, norm: normalized),
                      isValid(match, rule: rule, identifierRange: identifierRange,
                              norm: normalized, original: nsOriginal)
                else { continue }
                let key = "\(rule.category.rawValue)|\(identifierRange.location)|\(identifierRange.length)"
                guard seen.insert(key).inserted else { continue }
                pageFindings.append((identifierRange.location,
                    Finding(documentID: documentID,
                            pageIndex: page.pageIndex,
                            rects: page.rects(for: identifierRange),
                            text: nsOriginal.substring(with: identifierRange),
                            category: rule.category,
                            origin: .rule)))
            }
        }
        pageFindings.sort { $0.location < $1.location }
        return pageFindings.map(\.finding)
    }

    /// Extracts the identifier range (never the context label) for a match and
    /// maps it into the original page text.
    private func originalIdentifierRange(for match: NSTextCheckingResult,
                                         rule: RuleID,
                                         norm: NormalizedText) -> NSRange? {
        switch rule {
        case .email, .phoneInternational, .phoneContext, .birthDate,
             .insuranceContext, .patientIDContext:
            let range = match.range(at: 1)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return norm.originalRange(forNormalizedUTF16Range: range)
        case .insuranceNumber:
            return norm.originalRange(forNormalizedUTF16Range: match.range)
        case .street, .postalCode:
            let streetOrPLZ = match.range(at: 1)
            let numberOrCity = match.range(at: 2)
            guard streetOrPLZ.location != NSNotFound,
                  numberOrCity.location != NSNotFound,
                  streetOrPLZ.length > 0,
                  numberOrCity.length > 0
            else { return nil }
            let span = NSRange(location: streetOrPLZ.location,
                               length: numberOrCity.location + numberOrCity.length - streetOrPLZ.location)
            return norm.originalRange(forNormalizedUTF16Range: span)
        case .nameContext:
            // Ran on the original text; already in the right coordinate space.
            let range = match.range(at: 1)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return range
        }
    }

    /// Rule-specific post-validation that is easier in code than in regex.
    private func isValid(_ match: NSTextCheckingResult,
                         rule: RuleID,
                         identifierRange: NSRange,
                         norm: NormalizedText,
                         original: NSString) -> Bool {
        switch rule {
        case .email, .street, .insuranceNumber:
            return true

        case .phoneInternational, .phoneContext:
            // 7–15 digits is a plausible phone number; protects against
            // fragments like "Tel: 110" and against over-long digit runs.
            let digits = original.substring(with: identifierRange).filter(\.isNumber).count
            return (7...15).contains(digits)

        case .birthDate:
            let parts = original.substring(with: identifierRange).split(separator: ".")
            guard parts.count == 3,
                  let day = Int(parts[0]),
                  let month = Int(parts[1])
            else { return false }
            return (1...31).contains(day) && (1...12).contains(month)

        case .postalCode:
            let plzRange = match.range(at: 1)
            let cityRange = match.range(at: 2)
            guard let plzOriginal = norm.originalRange(forNormalizedUTF16Range: plzRange),
                  let cityOriginal = norm.originalRange(forNormalizedUTF16Range: cityRange)
            else { return false }
            guard let plz = Int(original.substring(with: plzOriginal)),
                  (1000...99998).contains(plz)
            else { return false }
            // Every city word must start with an uppercase letter in the
            // original text ("12345 Berlin", not "12345 berlin").
            let city = original.substring(with: cityOriginal)
            let cityNS = city as NSString
            var wordStarts: [Int] = []
            var inWord = false
            for offset in 0..<cityNS.length {
                let scalar = cityNS.character(at: offset)
                // Space, hyphen, newline, carriage return.
                let isSeparator = scalar == 32 || scalar == 45 || scalar == 10 || scalar == 13
                if isSeparator {
                    inWord = false
                } else if !inWord {
                    inWord = true
                    wordStarts.append(offset)
                }
            }
            guard !wordStarts.isEmpty else { return false }
            return wordStarts.allSatisfy {
                norm.isUppercaseLetterInOriginal(atUTF16Offset: cityOriginal.location + $0)
            }

        case .insuranceContext, .patientIDContext:
            // "Versichertennr. unbekannt" & co: a value must contain a digit.
            return original.substring(with: identifierRange).contains(where: \.isNumber)

        case .nameContext:
            let captured = original.substring(with: identifierRange)
            guard let firstWord = captured
                .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                .first
            else { return false }
            return !nameStopwords.contains(firstWord.lowercased())
        }
    }

    private static func compileAll() -> [RuleID: NSRegularExpression] {
        var result: [RuleID: NSRegularExpression] = [:]
        for rule in RuleID.allCases {
            result[rule] = try? NSRegularExpression(pattern: rule.pattern)
        }
        return result
    }
}
