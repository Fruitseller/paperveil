import Foundation
import os
import PaperVeilCore

/// LLM-based detection step (B03/B04). Calls the local LM Studio server per
/// page and turns the model's raw candidates into `Finding`s — but only after
/// validating every quote verbatim against the page text. Anything the model
/// reports that cannot be located in the document produces an unacknowledged
/// `ProcessingWarning` that blocks approval (Core handles the blocking); a
/// failing LLM step never silently counts as success.
///
/// Every warning message is neutral: it contains the page and the category,
/// never the quote or any document text (D07: keine Identifikatoren in Logs).
public struct LLMDetector: Sendable {
    private static let logger = Logger(subsystem: LMStudioClient.subsystem, category: "LLMDetector")

    /// Minimum length for an unambiguous quote (shorter → ambiguous warning).
    public static let minimumQuoteLength = 3

    public let client: LMStudioClient
    /// Per-page timeout for the model call.
    public let timeout: Duration

    public init(client: LMStudioClient, timeout: Duration = .seconds(120)) {
        self.client = client
        self.timeout = timeout
    }

    /// Runs LLM detection over all pages. Never throws: every failure mode
    /// becomes a `ProcessingWarning` on the result so the UI can require
    /// explicit review before approval.
    public func detect(pages: [PageText], documentID: DocumentID, model: String) async -> DetectionResult {
        var findings: [Finding] = []
        var warnings: [ProcessingWarning] = []
        for page in pages {
            // A page without text has no quotable identifiers; skip the model
            // call entirely instead of paying for (and validating) noise.
            guard !page.text.isEmpty, page.text.contains(where: { !$0.isWhitespace }) else { continue }
            do {
                let candidates = try await client.findCandidates(page: page, model: model, timeout: timeout)
                let (pageFindings, pageWarnings) = Self.evaluate(
                    candidates: candidates,
                    page: page,
                    documentID: documentID
                )
                findings.append(contentsOf: pageFindings)
                warnings.append(contentsOf: pageWarnings)
            } catch let failure as LMStudioFailure {
                Self.logger.warning(
                    "LLM-Schritt für Seite \(page.pageIndex, privacy: .private) fehlgeschlagen: \(failure.description, privacy: .public)"
                )
                warnings.append(
                    ProcessingWarning(
                        kind: Self.warningKind(for: failure),
                        pageIndex: page.pageIndex,
                        message: Self.message(for: failure, pageIndex: page.pageIndex)
                    )
                )
            } catch {
                warnings.append(
                    ProcessingWarning(
                        kind: .llmUnavailable,
                        pageIndex: page.pageIndex,
                        message: "Der LLM-Schritt für Seite \(page.pageIndex + 1) ist mit einem unbekannten Fehler fehlgeschlagen. Die Seite muss manuell geprüft werden."
                    )
                )
            }
        }
        return DetectionResult(findings: findings, warnings: warnings)
    }

    // MARK: Candidate validation (verbatim against page + geometry)

    /// Validates each candidate against the page text:
    /// - whitespace-normalised verbatim match, line breaks and hyphenated line
    ///   breaks between tokens allowed;
    /// - every occurrence on the page becomes a proposed finding with rects
    ///   from `PageText.rects(for:)`;
    /// - quote not found → `llmFabricatedQuote` (no finding);
    /// - quote shorter than `minimumQuoteLength` or only occurring inside
    ///   other words → `llmAmbiguousMatch` (no automatic finding);
    /// - invalid JSON / schema mismatch was already rejected by the client as
    ///   `llmInvalidResponse`.
    static func evaluate(
        candidates: [LLMCandidate],
        page: PageText,
        documentID: DocumentID
    ) -> ([Finding], [ProcessingWarning]) {
        var findings: [Finding] = []
        var warnings: [ProcessingWarning] = []
        var handledRanges = Set<RangeKey>() // avoid duplicate findings for the same span

        for candidate in candidates {
            let occurrences = LMStudioTextMatcher.occurrences(of: candidate.quote, in: page)
            let clean = occurrences.compactMap { if case .clean(let r) = $0 { return r } else { return nil } }
            let embedded = occurrences.compactMap { if case .embedded(let r) = $0 { return r } else { return nil } }

            if candidate.quote.count < minimumQuoteLength {
                warnings.append(
                    ProcessingWarning(
                        kind: .llmAmbiguousMatch,
                        pageIndex: page.pageIndex,
                        message: Self.ambiguousMessage(pageIndex: page.pageIndex, category: candidate.category)
                    )
                )
                continue
            }
            if clean.isEmpty {
                warnings.append(
                    ProcessingWarning(
                        kind: embedded.isEmpty ? .llmFabricatedQuote : .llmAmbiguousMatch,
                        pageIndex: page.pageIndex,
                        message: embedded.isEmpty
                            ? Self.fabricatedMessage(pageIndex: page.pageIndex, category: candidate.category)
                            : Self.ambiguousMessage(pageIndex: page.pageIndex, category: candidate.category)
                    )
                )
                continue
            }

            let nsText = page.text as NSString
            for range in clean where !handledRanges.contains(RangeKey(range)) {
                handledRanges.insert(RangeKey(range))
                findings.append(
                    Finding(
                        documentID: documentID,
                        pageIndex: page.pageIndex,
                        rects: page.rects(for: range),
                        text: nsText.substring(with: range),
                        category: candidate.category,
                        origin: .llm,
                        decision: .proposed
                    )
                )
            }
        }
        return (findings, warnings)
    }

    private struct RangeKey: Hashable {
        let location: Int
        let length: Int
        init(_ r: NSRange) { location = r.location; length = r.length }
    }

    // MARK: Failure → warning mapping (neutral messages, no quotes)

    private static func warningKind(for failure: LMStudioFailure) -> WarningKind {
        switch failure {
        case .timeout: .llmTimeout
        case .unreachable, .httpStatus: .llmUnavailable
        case .invalidResponse: .llmInvalidResponse
        }
    }

    private static func message(for failure: LMStudioFailure, pageIndex: Int) -> String {
        let page = pageIndex + 1
        return switch failure {
        case .timeout:
            "Der LLM-Schritt für Seite \(page) hat das Zeitlimit überschritten. Die Seite muss manuell geprüft werden."
        case .unreachable, .httpStatus:
            "Der lokale Modellserver ist nicht erreichbar; der LLM-Schritt für Seite \(page) wurde nicht ausgeführt. Die Seite muss manuell geprüft werden."
        case .invalidResponse(let reason):
            "Die Antwort des Modells für Seite \(page) war ungültig (\(reason)); es wurden keine automatischen Vorschläge übernommen. Die Seite muss manuell geprüft werden."
        }
    }

    private static func fabricatedMessage(pageIndex: Int, category: IdentifierCategory) -> String {
        "Das Modell meldete einen Identifikator (Kategorie: \(category.rawValue)) auf Seite \(pageIndex + 1), "
            + "der nicht wörtlich im Seitentext vorkommt; er wurde verworfen. Die Seite muss manuell geprüft werden."
    }

    private static func ambiguousMessage(pageIndex: Int, category: IdentifierCategory) -> String {
        "Das Modell meldete einen Identifikator (Kategorie: \(category.rawValue)) auf Seite \(pageIndex + 1), "
            + "der auf der Seite nicht eindeutig zuordenbar ist; es wurde kein automatischer Vorschlag erstellt. Die Seite muss manuell geprüft werden."
    }
}
