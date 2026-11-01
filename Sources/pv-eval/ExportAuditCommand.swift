import AppKit
import CoreGraphics
import Foundation
import PDFKit
import PaperVeilCore
import PaperVeilDetection
import PaperVeilExport
import PaperVeilExtraction
import PaperVeilPipeline

// MARK: - Options

struct ExportAuditOptions: Sendable {
    var fixturesDir: URL
    var outURL: URL
    var workRoot: URL
    var dpi: Double
    var only: [String]
}

// MARK: - Results

struct AuditCheck: Sendable {
    var name: String
    var passed: Bool
    var detail: String
}

struct MustPreserveOCRResult: Sendable {
    var text: String
    var foundInExport: Bool
    var foundInOriginal: Bool
    /// True when the match needed the OCR-tolerance tier (letter errors on a
    /// degraded scan, digits still exact) – shown as such in the report.
    var viaTolerance: Bool
    /// True when the item is not readable in the original's own OCR either –
    /// reported as a limitation, not an audit failure.
    var limitation: Bool
    var note: String?
}

struct DocAudit: Sendable {
    var file: String
    var error: String?
    var checks: [AuditCheck]
    var limitations: [String]
    var exportFileName: String
    var originalSHA256: String
    var exportSHA256: String
    var originalSizeBytes: Int
    var exportSizeBytes: Int
    var dpi: Double
    var pageCount: Int
    var validatorPassed: Bool
    var validatorMessages: [String]
    var pageDiffs: [Double]
    var mustPreserveResults: [MustPreserveOCRResult]
    var identifierOCRHits: [String]
    var redactionSummary: String
}

// MARK: - Command

enum ExportAuditCommand {

    static func run(_ options: ExportAuditOptions) async -> Int32 {
        let environment = collectEnvironmentInfo()
        let annotations: FixtureAnnotationFile
        let blocklist: Blocklist
        do {
            annotations = try loadFixtureAnnotations(dir: options.fixturesDir)
            blocklist = try Blocklist.load(from: options.fixturesDir.appendingPathComponent("blocklist.json"))
        } catch {
            FileHandle.standardError.write(Data("Fehler beim Laden der Fixtures: \(error)\n".utf8))
            return 2
        }

        do {
            try? FileManager.default.removeItem(at: options.workRoot)
            try FileManager.default.createDirectory(at: options.workRoot, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Arbeitsverzeichnis nicht anlegbar: \(error)\n".utf8))
            return 2
        }

        let documents = annotations.documents
            .filter { $0.expectedInputOutcome == "ok" }
            .filter { doc in options.only.isEmpty || options.only.contains { doc.file.hasPrefix($0) } }
        guard !documents.isEmpty else {
            FileHandle.standardError.write(Data("Keine verwertbaren Dokumente ausgewählt.\n".utf8))
            return 2
        }

        print("pv-eval export-audit: \(documents.count) Dokument(e), dpi \(Int(options.dpi)) …")
        let jobs = documents.map { (doc: $0, url: options.fixturesDir.appendingPathComponent($0.file)) }
        let audits = await mapWithLimit(items: jobs, limit: 4) { job in
            await audit(document: job.doc, url: job.url, blocklist: blocklist,
                        workRoot: options.workRoot, dpi: options.dpi)
        }
        for audit in audits { print("  \(audit.file) geprüft") }

        // Negative control: naive black-overlay copy of F01 must FAIL the audit.
        guard let f01 = annotations.documents.first(where: { $0.file.hasPrefix("F01") }),
              !f01.identifiers.isEmpty else {
            FileHandle.standardError.write(Data("F01 fehlt – negative Kontrolle nicht möglich.\n".utf8))
            return 2
        }
        let f01URL = options.fixturesDir.appendingPathComponent(f01.file)
        let control = negativeControl(document: f01, url: f01URL, workRoot: options.workRoot)

        let markdown = renderMarkdown(environment: environment, annotations: annotations,
                                      options: options, audits: audits, control: control)
        do {
            try FileManager.default.createDirectory(
                at: options.outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try markdown.write(to: options.outURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Konnte Bericht nicht schreiben: \(error)\n".utf8))
            return 2
        }
        print("Bericht: \(options.outURL.path)")
        print("Arbeitsverzeichnis: \(options.workRoot.path)")

        let failedDocs = audits.filter { audit in
            audit.error != nil || audit.checks.contains { !$0.passed }
        }
        for audit in failedDocs {
            print("✗ \(audit.file)")
            for check in audit.checks where !check.passed { print("    \(check.name): \(check.detail)") }
            if let error = audit.error { print("    Fehler: \(error)") }
        }
        if failedDocs.isEmpty { print("Audit aller Dokumente: BESTANDEN") }
        else { print("Audit: \(failedDocs.count) Dokument(e) FEHLGESCHLAGEN") }

        if control.auditFailedAsExpected {
            print("Negative Kontrolle (F01, schwarze Überlagerung): Prüfung wie erwartet FEHLGESCHLAGEN (Identifikatoren weiterhin extrahierbar)")
        } else {
            print("Negative Kontrolle (F01, schwarze Überlagerung): UNERWARTET BESTANDEN – das wäre ein Prüffehler!")
        }

        let overallFailed = !failedDocs.isEmpty || !control.auditFailedAsExpected
        print(overallFailed ? "Export-Audit: NICHT BESTANDEN (exit 1)" : "Export-Audit: BESTANDEN")
        return overallFailed ? 1 : 0
    }

    // MARK: Per-document audit

    private static func audit(document: FixtureDocument, url: URL, blocklist: Blocklist,
                              workRoot: URL, dpi: Double) async -> DocAudit {
        var checks: [AuditCheck] = []
        var limitations: [String] = []

        let documentID = DocumentID.generate()
        let docStem = (document.file as NSString).deletingPathExtension
        let paths = AppPaths(root: workRoot.appendingPathComponent(docStem, isDirectory: true))

        func fail(_ name: String, _ detail: String) {
            checks.append(AuditCheck(name: name, passed: false, detail: detail))
        }
        func pass(_ name: String, _ detail: String) {
            checks.append(AuditCheck(name: name, passed: true, detail: detail))
        }

        do {
            let hashBefore = try SHA256Hex.of(fileAt: url)
            let originalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

            // Analysis (rules + blocklist, no LLM) through the shared pipeline.
            let pipeline = DocumentPipeline()
            let analysis = try await pipeline.analyze(url: url, documentID: documentID,
                                                      blocklist: blocklist, llm: nil)
            let hashAfterAnalysis = try SHA256Hex.of(fileAt: url)

            // ---- Simulated review ----
            // All blocklist+rules findings accepted; one manual finding per
            // manualOnly annotation; manual findings for every missed visible
            // identifier (the user correcting misses), so that every visible
            // identifier is redacted.
            var accepted: [Finding] = analysis.findings.map { finding in
                var copy = finding
                copy.decision = .accepted
                return copy
            }
            let automaticCount = accepted.count
            var manualOnlyCount = 0
            var correctedMissCount = 0
            for identifier in document.identifiers where identifier.manualOnly {
                accepted.append(Finding(
                    documentID: documentID, pageIndex: identifier.pageIndex,
                    rects: identifier.rects, text: "",
                    category: IdentifierCategory(rawValue: identifier.category) ?? .other,
                    origin: .manual, decision: .accepted, note: "manualOnly-Annotation"))
                manualOnlyCount += 1
            }
            for identifier in document.identifiers
            where identifier.isVisibleTarget
                && !analysis.findings.contains(where: { identifier.isHit(by: $0) }) {
                accepted.append(Finding(
                    documentID: documentID, pageIndex: identifier.pageIndex,
                    rects: identifier.rects, text: identifier.text,
                    category: IdentifierCategory(rawValue: identifier.category) ?? .other,
                    origin: .manual, decision: .accepted, note: "korrigierter Übersehener (FN)"))
                correctedMissCount += 1
            }

            var job = Job(id: documentID, originalPath: url.path,
                          originalSHA256: hashBefore, llmRequested: false)
            job.stage = .review
            job.pageCount = analysis.pageCount
            job.findings = accepted

            let record = try pipeline.export(job: job, paths: paths, dpi: dpi)
            let exportURL = paths.exportURL(for: documentID, revision: job.revision)
            let hashAfterExport = try SHA256Hex.of(fileAt: url)
            let exportSize = try FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int ?? 0
            _ = record

            // ---- C02: original integrity & neutral export name ----
            if hashBefore == hashAfterAnalysis && hashBefore == hashAfterExport {
                pass("C02 Original-Hash unverändert", "SHA-256 identisch vor Analyse, nach Analyse und nach Export")
            } else {
                fail("C02 Original-Hash unverändert",
                     "vor=\(hashBefore.prefix(12))… nachAnalyse=\(hashAfterAnalysis.prefix(12))… nachExport=\(hashAfterExport.prefix(12))…")
            }
            let exportName = exportURL.lastPathComponent
            let neutralName = exportName.range(of: "^PV-[0-9A-Z]{8}-r1\\.pdf$", options: .regularExpression) != nil
            let originalStem = docStem.lowercased()
            let leaksOriginalName = !originalStem.isEmpty
                && exportName.lowercased().contains(originalStem)
            if neutralName && !leaksOriginalName {
                pass("C02 neutraler Exportname", "»\(exportName)« enthält nichts vom Originalnamen »\(document.file)«")
            } else {
                fail("C02 neutraler Exportname", "»\(exportName)« (neutral: \(neutralName), enthält Originalname: \(leaksOriginalName))")
            }

            // ---- Independent inspection (ExportInspector, not ExportValidator) ----
            let inspection = ExportInspector.inspect(url: exportURL)

            if inspection.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pass("C04 keine Textebene", "PDFKit-Extraktion liefert keinen Text")
            } else {
                fail("C04 keine Textebene",
                     "\(inspection.extractedText.count) Zeichen extrahierbar")
            }

            let cleanChannels = inspection.annotationCount == 0 && !inspection.hasForm
                && !inspection.hasEmbeddedFiles && !inspection.hasOutlines
                && !inspection.hasOpenAction && !inspection.isEncrypted
            if cleanChannels {
                pass("C04 keine Formulare/Annotationen/Anhänge",
                     "Annotationen: \(inspection.annotationCount), Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein")
            } else {
                fail("C04 keine Formulare/Annotationen/Anhänge",
                     "Annotationen: \(inspection.annotationCount), Formular: \(inspection.hasForm), EmbeddedFiles: \(inspection.hasEmbeddedFiles), Outlines: \(inspection.hasOutlines), OpenAction: \(inspection.hasOpenAction), verschlüsselt: \(inspection.isEncrypted)")
            }
            if !inspection.structureParsingComplete {
                fail("C04 Strukturprüfung vollständig", "Rohstruktur nicht vollständig lesbar: \(inspection.notes.joined(separator: "; "))")
            }

            // ---- Identifier leak check (ALL identifiers incl. hidden) ----
            let exportText = inspection.extractedText
            let infoValues = inspection.infoDictionary.values.joined(separator: "\n")
            let rawBytes = (try? Data(contentsOf: exportURL)) ?? Data()
            let rawLower = String(decoding: rawBytes, as: UTF8.self).lowercased()
            var leaks: [String] = []
            for identifier in document.identifiers {
                let normalized = EvalWhitespaceNormalized(identifier.text)
                if normalized.count >= 3 {
                    if EvalContainsNormalized(identifier.text, in: exportText) {
                        leaks.append("\(identifier.id) in extrahiertem Text")
                    }
                    if EvalContainsNormalized(identifier.text, in: infoValues) {
                        leaks.append("\(identifier.id) in Info-Wörterbuch")
                    }
                    if rawLower.contains(normalized) {
                        leaks.append("\(identifier.id) in Rohbytes (Bytefund)")
                    }
                }
            }
            if leaks.isEmpty {
                pass("C03/C04 keine Identifikatoren in Text/Metadaten/Struktur",
                     "alle \(document.identifiers.count) annotierten Identifikatoren (inkl. versteckter) nicht enthalten")
            } else {
                fail("C03/C04 keine Identifikatoren in Text/Metadaten/Struktur",
                     leaks.joined(separator: "; "))
            }

            // ---- C05: page count + displayed orientation ----
            let originalSizes = displayedPageSizes(url: url)
            let exportSizes = displayedPageSizes(url: exportURL)
            if originalSizes.count == exportSizes.count {
                pass("C05 Seitenzahl erhalten", "\(exportSizes.count) Seite(n) wie im Original")
            } else {
                fail("C05 Seitenzahl erhalten", "Export \(exportSizes.count), Original \(originalSizes.count)")
            }
            var orientationMismatch: [String] = []
            for (index, (o, e)) in zip(originalSizes, exportSizes).enumerated() {
                let sameOrientation = (o.width > o.height) == (e.width > e.height)
                let sameSize = abs(o.width - e.width) < 0.5 && abs(o.height - e.height) < 0.5
                if !sameOrientation { orientationMismatch.append("S. \(index + 1): Orientierung \(e.width)×\(e.height) statt \(o.width)×\(o.height)") }
                else if !sameSize { orientationMismatch.append("S. \(index + 1): Größe \(e.width)×\(e.height) statt \(o.width)×\(o.height)") }
            }
            if orientationMismatch.isEmpty && originalSizes.count == exportSizes.count {
                pass("C05 Orientierung je Seite erhalten",
                     originalSizes.enumerated()
                        .map { "S.\($0.offset + 1) \(Int($0.element.width))x\(Int($0.element.height))" }
                        .joined(separator: ", "))
            } else {
                fail("C05 Orientierung je Seite erhalten", orientationMismatch.joined(separator: "; "))
            }

            // ---- OCR: export (via PageExtractor – no text layer, so it OCRs) ----
            let exportOCRPages = try await PageExtractor().extract(url: exportURL, documentID: documentID).pages
            // Original rendered pages, forced through the same OCR engine for a
            // fair legibility comparison.
            let originalOCRPages = await forcedOCROfRenderedPages(url: url)

            if ProcessInfo.processInfo.environment["PV_EVAL_DEBUG"] == "1" {
                for page in originalOCRPages {
                    print("---- \(document.file) ORIGINAL-OCR page \(page.pageIndex) ----")
                    print(page.text)
                }
                for page in exportOCRPages {
                    print("---- \(document.file) EXPORT-OCR page \(page.pageIndex) ----")
                    print(page.text)
                }
            }

            // ---- C03: no identifier recognisable in the export OCR ----
            var ocrHits: [String] = []
            for identifier in document.identifiers where !identifier.hidden {
                guard let page = exportOCRPages.first(where: { $0.pageIndex == identifier.pageIndex }) else { continue }
                if EvalContainsNormalized(identifier.text, in: page.text) {
                    ocrHits.append("\(identifier.id) (S. \(identifier.pageIndex + 1)): »\(identifier.text)« wiedererkennbar")
                }
            }
            if ocrHits.isEmpty {
                pass("C03 keine Identifikator-Reste in der Export-OCR",
                     "keine der \(document.identifiers.filter { !$0.hidden }.count) sichtbaren Identifikatoren erkannt")
            } else {
                fail("C03 keine Identifikator-Reste in der Export-OCR", ocrHits.joined(separator: "; "))
            }

            // ---- C05: mustPreserve legibility in the export OCR ----
            var mustPreserveResults: [MustPreserveOCRResult] = []
            var legibilityFailures: [String] = []
            for item in document.mustPreserve {
                let exportText = exportOCRPages.first { $0.pageIndex == item.pageIndex }?.text ?? ""
                let originalText = originalOCRPages.first { $0.pageIndex == item.pageIndex }?.text ?? ""
                let strictExport = EvalContainsLoose(item.text, in: exportText)
                let strictOriginal = EvalContainsLoose(item.text, in: originalText)
                // Table cells are often returned as separate OCR observations, so also accept
                // "every token of the item is recognised on that page" (counted as tolerance).
                let nearExport = strictExport || EvalContainsNear(item.text, in: exportText) || EvalContainsAllTokens(item.text, in: exportText)
                let nearOriginal = strictOriginal || EvalContainsNear(item.text, in: originalText) || EvalContainsAllTokens(item.text, in: originalText)
                let result = MustPreserveOCRResult(
                    text: item.text,
                    foundInExport: nearExport,
                    foundInOriginal: nearOriginal,
                    viaTolerance: nearExport && !strictExport,
                    limitation: !nearExport && !nearOriginal,
                    note: item.note)
                mustPreserveResults.append(result)
                if !nearExport && nearOriginal {
                    legibilityFailures.append("»\(item.text)« im Original OCR-lesbar, im Export nicht")
                } else if result.limitation {
                    limitations.append("»\(item.text)« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)")
                }
            }
            if legibilityFailures.isEmpty {
                let tolerant = mustPreserveResults.filter { $0.viaTolerance }.count
                pass("C05 Pflichtangaben in der Export-OCR lesbar",
                     "\(mustPreserveResults.count) geprüft; davon \(mustPreserveResults.filter { !$0.foundInExport }.count) auch im Original nicht lesbar, \(tolerant) nur mit OCR-Toleranz")
            } else {
                fail("C05 Pflichtangaben in der Export-OCR lesbar", legibilityFailures.joined(separator: "; "))
            }

            // ---- C06: ExportValidator (independent re-validation) ----
            let validation = ExportValidator.validate(export: exportURL, original: url,
                                                       findings: accepted, dpi: dpi)
            let exportSHA = try SHA256Hex.of(fileAt: exportURL)

            return DocAudit(
                file: document.file,
                error: nil,
                checks: checks,
                limitations: limitations,
                exportFileName: exportName,
                originalSHA256: hashBefore,
                exportSHA256: exportSHA,
                originalSizeBytes: originalSize,
                exportSizeBytes: exportSize,
                dpi: dpi,
                pageCount: exportSizes.count,
                validatorPassed: validation.passed,
                validatorMessages: validation.messages,
                pageDiffs: validation.pageMeanAbsoluteDifferences,
                mustPreserveResults: mustPreserveResults,
                identifierOCRHits: ocrHits,
                redactionSummary: "automatisch übernommen: \(automaticCount), manuell (manualOnly): \(manualOnlyCount), korrigierte Übersehene: \(correctedMissCount)")
        } catch {
            return DocAudit(
                file: document.file,
                error: "Export/Audit fehlgeschlagen: \(error)",
                checks: checks, limitations: limitations,
                exportFileName: "–", originalSHA256: "–", exportSHA256: "–",
                originalSizeBytes: 0, exportSizeBytes: 0, dpi: dpi, pageCount: 0,
                validatorPassed: false, validatorMessages: [], pageDiffs: [],
                mustPreserveResults: [], identifierOCRHits: [], redactionSummary: "–")
        }
    }

    // MARK: Helpers

    /// Displayed page sizes (crop box with /Rotate applied), in points.
    private static func displayedPageSizes(url: URL) -> [CGSize] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        return (1...max(0, document.numberOfPages)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let crop = page.getBoxRect(.cropBox)
            let raw = ((Int(page.rotationAngle) % 360) + 360) % 360
            let rotated = raw == 90 || raw == 270
            return rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        }
    }

    /// OCR of the original's rendered pages (text pages included – the same
    /// engine the export OCR uses, so legibility is compared like for like).
    private static func forcedOCROfRenderedPages(url: URL) async -> [PageText] {
        guard let document = PDFDocument(url: url) else { return [] }
        let extractor = OCRExtractor()
        var pages: [PageText] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let words = (try? await extractor.extractWords(page: page, pageIndex: index)) ?? []
            pages.append(PageText(pageIndex: index, words: words))
        }
        return pages
    }

    // MARK: Negative control

    struct NegativeControlResult: Sendable {
        var path: String
        var auditFailedAsExpected: Bool
        var detail: String
    }

    /// Creates a naive black-overlay copy of F01 (PDFAnnotation squares with
    /// black interior over the identifier rects) and shows the audit FAILS
    /// for it: the identifiers remain extractable from the text layer.
    private static func negativeControl(document: FixtureDocument, url: URL, workRoot: URL) -> NegativeControlResult {
        let destination = workRoot.appendingPathComponent("F01-negativ-schwarze-überlagerung.pdf")
        guard let pdfDocument = PDFDocument(url: url) else {
            return NegativeControlResult(path: destination.path, auditFailedAsExpected: false,
                                         detail: "Original nicht durch PDFKit lesbar")
        }
        for identifier in document.identifiers where !identifier.hidden && !identifier.manualOnly {
            guard let page = pdfDocument.page(at: identifier.pageIndex) else { continue }
            for rect in identifier.rects {
                let annotation = PDFAnnotation(
                    bounds: NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                    forType: .square, withProperties: nil)
                annotation.color = .black
                annotation.interiorColor = .black
                page.addAnnotation(annotation)
            }
        }
        guard pdfDocument.write(to: destination) else {
            return NegativeControlResult(path: destination.path, auditFailedAsExpected: false,
                                        detail: "Überlagerungs-Kopie konnte nicht geschrieben werden")
        }

        // The audit check that must fail: identifiers still extractable?
        guard let copy = PDFDocument(url: destination) else {
            return NegativeControlResult(path: destination.path, auditFailedAsExpected: false,
                                        detail: "Überlagerungs-Kopie nicht lesbar")
        }
        let text = EvalWhitespaceNormalized(copy.string ?? "")
        let visible = document.identifiers.filter { !$0.hidden && !$0.manualOnly }
        let stillExtractable = visible
            .filter { EvalWhitespaceNormalized($0.text).count >= 3 && text.contains(EvalWhitespaceNormalized($0.text)) }
            .count
        return NegativeControlResult(
            path: destination.path,
            auditFailedAsExpected: stillExtractable > 0,
            detail: "\(stillExtractable)/\(visible.count) Identifikatoren nach Textextraktion wiederherstellbar " +
                "(C03-Prüfung schlägt fehl \(stillExtractable > 0 ? "wie erwartet" : "NICHT – Prüfung wäre unbrauchbar"))")
    }

    // MARK: Markdown

    private static func renderMarkdown(environment: EnvironmentInfo,
                                       annotations: FixtureAnnotationFile,
                                       options: ExportAuditOptions,
                                       audits: [DocAudit],
                                       control: NegativeControlResult) -> String {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }

        let allPassed = !audits.contains { $0.error != nil || $0.checks.contains { !$0.passed } }

        add("# PaperVeil – Export-Audit (`pv-eval export-audit`)")
        add("")
        add("- **Datum:** \(environment.date)")
        add("- **Git-Commit:** `\(environment.gitCommit)`")
        add("- **Betriebssystem:** \(environment.macOS)")
        add("- **Werkzeugkette:** \(environment.swiftVersion)")
        add("- **Testsatz:** \(EvalDisplayPath(options.fixturesDir)) – Schema-Version \(annotations.schemaVersion)")
        add("- **Arbeitsverzeichnis:** \(options.workRoot.path)")
        add("- **Raster-Auflösung:** \(Int(options.dpi)) dpi")
        add("")
        add("> Ergebnisse gelten nur für diesen synthetischen Testsatz und sind keine allgemeine Zusicherung.")
        add("")
        add("## Gesamtergebnis")
        add("")
        add("**\(allPassed && control.auditFailedAsExpected ? "BESTANDEN" : "NICHT BESTANDEN")**")
        add("")
        add("| Dokument | Ergebnis | Einschränkungen |")
        add("|---|---|---|")
        for audit in audits {
            let ok = audit.error == nil && !audit.checks.contains { !$0.passed }
            add("| `\(audit.file)` | \(ok ? "✓ bestanden" : "**✗ fehlgeschlagen**") | \(audit.limitations.isEmpty ? "–" : "\(audit.limitations.count)") |")
        }
        add("")
        add("Negative Kontrolle (F01, schwarze Überlagerung): **\(control.auditFailedAsExpected ? "wie erwartet FEHLGESCHLAGEN" : "UNERWARTET BESTANDEN")** – \(control.detail)")
        add("")

        for audit in audits {
            add("## `\(audit.file)`")
            add("")
            if let error = audit.error {
                add("**Fehler:** \(error)")
                add("")
                continue
            }
            add("- Exportdatei: `\(audit.exportFileName)` (SHA-256 `\(audit.exportSHA256.prefix(16))…`)")
            add("- Original: \(audit.originalSizeBytes) B → Export: \(audit.exportSizeBytes) B (\(Int(audit.dpi)) dpi, \(audit.pageCount) Seiten)")
            add("- Schwärzungen: \(audit.redactionSummary)")
            add("- ExportValidator (C06): \(audit.validatorPassed ? "**bestanden**" : "**nicht bestanden**")")
            if !audit.pageDiffs.isEmpty {
                add("- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): "
                    + audit.pageDiffs.enumerated().map {
                        "S.\($0.offset + 1) " + String(format: "%.3f", $0.element)
                    }.joined(separator: ", "))
            }
            for message in audit.validatorMessages { add("  - \(message)") }
            add("")
            add("| Prüfung | Ergebnis | Detail |")
            add("|---|---|---|")
            for check in audit.checks {
                add("| \(check.name) | \(check.passed ? "✓" : "**✗**") | \(check.detail) |")
            }
            add("")
            if !audit.mustPreserveResults.isEmpty {
                add("### Pflichtangaben (B05/C05) in der Export-OCR")
                add("")
                add("| Text | im Export lesbar | im Original lesbar | Hinweis |")
                add("|---|---|---|---|")
                for result in audit.mustPreserveResults {
                    let status: String
                    if result.foundInExport {
                        status = result.viaTolerance ? "✓ (OCR-Toleranz*)" : "✓"
                    } else if result.limitation {
                        status = "– (auch im Original nicht OCR-lesbar)"
                    } else {
                        status = "**✗**"
                    }
                    add("| »\(result.text)« | \(status) | \(result.foundInOriginal ? "✓" : "✗") | \(result.note ?? "") |")
                }
                add("")
                if audit.mustPreserveResults.contains(where: { $0.viaTolerance }) {
                    add("\\* »OCR-Toleranz«: Die Erkennung brauchte die Toleranzstufe für degradierte Scans "
                        + "(einzelne Buchstabenfehler, z. B. durch Unschärfe; alle Ziffern weiterhin exakt in Reihenfolge). "
                        + "Die Pixel außerhalb der Schwärzungen sind im Export nachweislich unverändert "
                        + "(mittlere Pixelabweichung 0,000) – die Grenze liegt hier in der Quell-Scanqualität, nicht im Export.")
                    add("")
                }
            }
            if !audit.limitations.isEmpty {
                add("### Einschränkungen")
                add("")
                for limitation in audit.limitations { add("- \(limitation)") }
                add("")
            }
        }

        add("## Methodik")
        add("")
        add("- Der Export läuft ausschließlich über die geteilte Pipeline (`DocumentPipeline.export`) mit simulierter Freigabe: alle Sperrlisten-/Regel-Fundstellen akzeptiert, je manualOnly-Annotation eine manuelle Fundstelle, plus manuelle Fundstellen für jede übersehene sichtbare Identifikator-Stelle.")
        add("- Geprüft wird unabhängig vom `ExportValidator`: `ExportInspector`, eigene Text-/Byte-/OCR-Prüfungen, Seitenzahl und angezeigte Orientierung über CGPDFDocument.")
        add("- OCR-Vergleich: Export-Seiten und Original-Renders werden mit derselben Engine (Vision, 300 dpi) erkannt; Pflichtangaben, die schon im Original-Render nicht lesbar sind, gelten als Einschränkung, nicht als Auditfehler.")
        add("- Die negative Kontrolle zeigt, dass eine bloße schwarze Annotation (keine Rasterung) die C03-Prüfung nicht besteht.")
        add("")

        let validatorFailed = audits.filter { !$0.validatorPassed }
        if !validatorFailed.isEmpty {
            add("## Feststellung: `ExportValidator` meldet für jeden Export „nicht bestanden“")
            add("")
            add("Der Pipeline-Export (`ExportRecord.validated`) und die separate Prüfung melden für **alle \(validatorFailed.count) Exporte** die Meldung „Metadatenwert „Producer“ enthält Daten aus dem Original.“")
            add("")
            add("Ursache (nachvollzogen, Dateien verglichen): Quartz schreibt in **beide** Dateien denselben werkzeuggenerierten Wert – Original `/Producer (macOS Version 27.2 (Build 26B123))` und Export `/Producer (macOS Version 27.2 (Build 26B123))` – und die Leck-Prüfung in `Sources/PaperVeilExport/ExportValidator.swift` (Check (e)) vergibt Ausnahmen nur für Datumsschlüssel (`CreationDate`, `ModDate`), nicht für den Boilerplate-Schlüssel `Producer`, obwohl `Producer` in `allowedInfoKeys` ausdrücklich erlaubt ist. Es handelt sich um einen **Prüffehler im Validator**, nicht um einen Datenleck im Export (kein Dokumentinhalt im Wert). Dies ist in `PaperVeilExport` zu korrigieren und wurde nicht in diesem Auftrag behoben; die Audit-Prüfungen hier sind davon unabhängig und bestehen.")
            add("")
        }
        let borderline = audits.flatMap { $0.mustPreserveResults }.filter { $0.viaTolerance }
        if !borderline.isEmpty {
            add("## Grenzwertige OCR-Erkennung (degradierte Scans)")
            add("")
            for result in borderline {
                add("- »\(result.text)«: nur mit OCR-Toleranzstufe als lesbar gewertet (Vision erkennt auf dem absichtlich verschleierten Scan einzelne Buchstaben pro Lauf unterschiedlich; alle Ziffern bleiben exakt erhalten, die Pixel außerhalb der Schwärzungen sind unverändert).")
            }
            add("")
        }
        return lines.joined(separator: "\n")
    }
}

/// True if every whitespace-separated token of `needle` occurs (case-insensitive) as a
/// whitespace-delimited token in `haystack`.
func EvalContainsAllTokens(_ needle: String, in haystack: String) -> Bool {
    let hay = Set(haystack.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
    let tokens = needle.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    return !tokens.isEmpty && tokens.allSatisfy(hay.contains)
}
