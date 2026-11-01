import Foundation
import PaperVeilCore
import PaperVeilDetection
import PaperVeilExtraction
import PaperVeilPipeline

// MARK: - Options

struct LLMRunConfig: Sendable {
    var endpoint: LMStudioEndpoint
    var model: String
    var timeoutSeconds: Double
}

struct ReportOptions: Sendable {
    var fixturesDir: URL
    var outURL: URL
    var jsonURL: URL?
    var llm: LLMRunConfig?
    var only: [String]
}

// MARK: - Per-document report

struct HiddenItemReport: Codable, Sendable {
    var id: String
    var page: Int
    var category: String
    var channel: String?
    var text: String
}

struct LLMPageReport: Codable, Sendable {
    var page: Int
    var latencySeconds: Double
    var findings: Int
    var warnings: [String: Int]
}

struct DocReport: Codable, Sendable {
    var file: String
    var expectedOutcome: String
    var actualOutcome: String
    var inputDetail: String
    var analysisRan: Bool
    var pageCount: Int
    var extractionWarnings: [String]
    var methods: [MethodReport]
    var hiddenIdentifiers: [HiddenItemReport]
    var manualIdentifiers: [HiddenItemReport]
    var unlocatedMustPreserve: [String]
    var llmPages: [LLMPageReport]?
    var error: String?
}

// MARK: - Gate

struct GateResult: Codable, Sendable {
    var label: String
    var passed: Bool
    var skipped: Bool
    var failures: [String]
}

// MARK: - Command

enum ReportCommand {

    static func run(_ options: ReportOptions) async -> Int32 {
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

        let documents = annotations.documents.filter { doc in
            options.only.isEmpty || options.only.contains { doc.file.hasPrefix($0) }
        }
        guard !documents.isEmpty else {
            FileHandle.standardError.write(Data("Keine Dokumente ausgewählt (--only).\n".utf8))
            return 2
        }

        // Validate the requested model against the server's /v1/models list.
        if let llm = options.llm {
            let client = LMStudioClient(endpoint: llm.endpoint)
            do {
                let models = try await client.listModels()
                guard models.contains(llm.model) else {
                    FileHandle.standardError.write(Data((
                        "Modell „\(llm.model)“ wird vom Server \(llm.endpoint) nicht angeboten.\n"
                            + "Verfügbare Modelle: \(models.joined(separator: ", "))\n").utf8))
                    return 2
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "LM Studio unter \(llm.endpoint) nicht erreichbar: \(error)\n".utf8))
                return 2
            }
        }

        print("pv-eval report: \(documents.count) Dokument(e) …")

        // With an LLM run, documents are processed sequentially so the
        // per-page latency measurements are not distorted by server queuing.
        let reports: [DocReport]
        if options.llm != nil {
            var collected: [DocReport] = []
            for doc in documents {
                let url = options.fixturesDir.appendingPathComponent(doc.file)
                collected.append(await process(document: doc, url: url, blocklist: blocklist, llm: options.llm))
                print("  \(doc.file) fertig")
            }
            reports = collected
        } else {
            let jobs = documents.map { (doc: $0, url: options.fixturesDir.appendingPathComponent($0.file)) }
            reports = await mapWithLimit(items: jobs, limit: 4) { job in
                await process(document: job.doc, url: job.url, blocklist: blocklist, llm: nil)
            }
        }

        let gates = evaluateGate(reports: reports, annotations: annotations, only: options.only)

        let markdown = renderMarkdown(
            environment: environment, annotations: annotations, blocklist: blocklist,
            options: options, reports: reports, gates: gates)

        do {
            try FileManager.default.createDirectory(
                at: options.outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try markdown.write(to: options.outURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Konnte Bericht nicht schreiben: \(error)\n".utf8))
            return 2
        }
        print("Bericht: \(options.outURL.path)")

        if let jsonURL = options.jsonURL {
            do {
                let payload = ReportJSON(
                    meta: ReportMeta(
                        generated: environment.date, gitCommit: environment.gitCommit,
                        macOS: environment.macOS, swiftVersion: environment.swiftVersion,
                        fixturesSchemaVersion: annotations.schemaVersion,
                        blocklistEntries: blocklist.entries.count,
                        llmModel: options.llm?.model,
                        llmEndpoint: options.llm.map { $0.endpoint.description },
                        llmTimeoutSeconds: options.llm.map { $0.timeoutSeconds }),
                    gates: gates, documents: reports)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(payload).write(to: jsonURL, options: .atomic)
                print("JSON:   \(jsonURL.path)")
            } catch {
                FileHandle.standardError.write(Data("Konnte JSON nicht schreiben: \(error)\n".utf8))
                return 2
            }
        }

        for gate in gates {
            let symbol = gate.skipped ? "—" : (gate.passed ? "✓" : "✗")
            print("Gate \(gate.label): \(symbol)")
            if !gate.passed && !gate.skipped {
                for failure in gate.failures { print("    \(failure)") }
            }
        }
        let failed = gates.contains { !$0.skipped && !$0.passed }
        print(failed
            ? "Pflicht-Regressionssatz: NICHT BESTANDEN (exit 1)"
            : "Pflicht-Regressionssatz: BESTANDEN")
        return failed ? 1 : 0
    }

    // MARK: Per-document processing

    private static func process(document: FixtureDocument, url: URL, blocklist: Blocklist,
                                llm: LLMRunConfig?) async -> DocReport {
        let documentID = DocumentID.generate()

        // 1. Input validation vs expectedInputOutcome.
        var actual = "ok"
        var inputDetail = "Eingabe gültig, \(document.pageCount) Seite(n) erwartet"
        do {
            let validated = try InputValidator.validate(url: url)
            inputDetail = "Eingabe gültig, \(validated.pageCount) Seite(n)"
        } catch let error as InputError {
            switch error {
            case .encryptedOrLocked: actual = "encrypted"
            default: actual = "damaged"
            }
            inputDetail = error.description
        } catch {
            actual = "damaged"
            inputDetail = "Unerwarteter Prüfungsfehler: \(error)"
        }

        guard actual == "ok" else {
            return DocReport(file: document.file, expectedOutcome: document.expectedInputOutcome,
                             actualOutcome: actual, inputDetail: inputDetail, analysisRan: false,
                             pageCount: 0, extractionWarnings: [], methods: [],
                             hiddenIdentifiers: [], manualIdentifiers: [],
                             unlocatedMustPreserve: [], llmPages: nil, error: nil)
        }

        // 2. Pipeline extraction once (rules + blocklist, no LLM).
        do {
            let pipeline = DocumentPipeline()
            let analysis = try await pipeline.analyze(
                url: url, documentID: documentID, blocklist: blocklist, llm: nil)

            let blocklistFindings = blocklist.detect(in: analysis.pages, documentID: documentID)
            let ruleFindings = RuleDetector().detect(in: analysis.pages, documentID: documentID)

            if ProcessInfo.processInfo.environment["PV_EVAL_DEBUG"] == "1" {
                for page in analysis.pages {
                    print("---- \(document.file) page \(page.pageIndex) text ----")
                    print(page.text)
                }
                for finding in blocklistFindings + ruleFindings {
                    print("DBG \(document.file) p\(finding.pageIndex) \(finding.origin.rawValue) \(finding.category.rawValue) »\(finding.text)«")
                }
            }

            // mustPreserve locations (text search on text pages, given rect on scans).
            var located: [LocatedMustPreserve] = []
            var unlocated: [String] = []
            for item in document.mustPreserve {
                if let rect = item.rect {
                    located.append(LocatedMustPreserve(item: item, rects: [rect], located: true))
                } else if let page = analysis.pages.first(where: { $0.pageIndex == item.pageIndex }),
                          let rects = EvalPageRects(of: item.text, in: page) {
                    located.append(LocatedMustPreserve(item: item, rects: rects, located: true))
                } else {
                    unlocated.append(item.text)
                    located.append(LocatedMustPreserve(item: item, rects: [], located: false))
                }
            }

            var methods: [MethodReport] = [
                evaluateMethod(key: "blocklist", displayName: "Sperrliste",
                               findings: blocklistFindings, document: document, mustPreserve: located),
                evaluateMethod(key: "rules", displayName: "Regeln",
                               findings: ruleFindings, document: document, mustPreserve: located),
                evaluateMethod(key: "combined", displayName: "Kombiniert (Sperrliste+Regeln)",
                               findings: analysis.findings, document: document, mustPreserve: located),
            ]

            var llmPages: [LLMPageReport]?
            if let llm {
                let detector = LLMDetector(
                    client: LMStudioClient(endpoint: llm.endpoint),
                    timeout: .seconds(llm.timeoutSeconds))
                var llmFindings: [Finding] = []
                var llmWarnings: [ProcessingWarning] = []
                var pages: [LLMPageReport] = []
                for page in analysis.pages
                where !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let start = ContinuousClock.now
                    let result = await detector.detect(pages: [page], documentID: documentID, model: llm.model)
                    let elapsed = start.duration(to: .now)
                    llmFindings += result.findings
                    llmWarnings += result.warnings
                    var warningsByKind: [String: Int] = [:]
                    for warning in result.warnings {
                        warningsByKind[warning.kind.rawValue, default: 0] += 1
                    }
                    pages.append(LLMPageReport(
                        page: page.pageIndex,
                        latencySeconds: elapsed.secondsValue,
                        findings: result.findings.count,
                        warnings: warningsByKind))
                }
                llmPages = pages
                methods.append(evaluateMethod(key: "llm", displayName: "LLM",
                                               findings: llmFindings, document: document, mustPreserve: located))
                let union = DocumentPipeline.deduplicate(blocklistFindings + ruleFindings + llmFindings)
                methods.append(evaluateMethod(key: "combined_llm",
                                              displayName: "Kombiniert (Sperrliste+Regeln+LLM)",
                                              findings: union, document: document, mustPreserve: located))
            }

            let hidden = document.identifiers
                .filter { $0.hidden }
                .map { HiddenItemReport(id: $0.id, page: $0.pageIndex, category: $0.category,
                                        channel: $0.channel, text: $0.text) }
            let manual = document.identifiers
                .filter { $0.manualOnly }
                .map { HiddenItemReport(id: $0.id, page: $0.pageIndex, category: $0.category,
                                        channel: $0.channel, text: $0.text) }

            var warningsText = analysis.warnings.map { warning in
                "S. \( (warning.pageIndex ?? 0) + 1): [\(warning.kind.rawValue)] \(warning.message)"
            }
            if llm != nil {
                // LLM warnings counted per document (fabricated/ambiguous/invalid/timeout).
                for page in llmPages ?? [] {
                    for (kind, count) in page.warnings.sorted(by: { $0.key < $1.key }) {
                        warningsText.append("LLM S. \(page.page + 1): \(count)× \(kind)")
                    }
                }
            }

            return DocReport(
                file: document.file,
                expectedOutcome: document.expectedInputOutcome,
                actualOutcome: actual,
                inputDetail: inputDetail,
                analysisRan: true,
                pageCount: analysis.pageCount,
                extractionWarnings: warningsText,
                methods: methods,
                hiddenIdentifiers: hidden,
                manualIdentifiers: manual,
                unlocatedMustPreserve: unlocated,
                llmPages: llmPages,
                error: nil)
        } catch {
            return DocReport(file: document.file, expectedOutcome: document.expectedInputOutcome,
                              actualOutcome: actual, inputDetail: inputDetail, analysisRan: false,
                              pageCount: 0, extractionWarnings: [], methods: [],
                              hiddenIdentifiers: [], manualIdentifiers: [],
                              unlocatedMustPreserve: [], llmPages: nil,
                              error: "Pipeline-Fehler: \(error)")
        }
    }

    // MARK: Gate

    private static func evaluateGate(reports: [DocReport], annotations: FixtureAnnotationFile,
                                     only: [String]) -> [GateResult] {
        var gates: [GateResult] = []

        // (a) every document's input outcome matches expectedInputOutcome.
        let inputFailures = reports.compactMap { report -> String? in
            guard report.expectedOutcome == report.actualOutcome else {
                return "\(report.file): erwartet \(report.expectedOutcome), tatsächlich \(report.actualOutcome) (\(report.inputDetail))"
            }
            return nil
        }
        gates.append(GateResult(
            label: "(a) Eingabe-Ergebnis je Dokument entspricht expectedInputOutcome",
            passed: inputFailures.isEmpty, skipped: false, failures: inputFailures))

        // (b) rules+blocklist combined find every annotated identifier that is
        //     not hidden, not manualOnly and not expectOCRUncertain.
        var recallFailures: [String] = []
        for report in reports {
            if let error = report.error {
                recallFailures.append("\(report.file): Analyse fehlgeschlagen (\(error))")
                continue
            }
            guard let combined = report.methods.first(where: { $0.key == "combined" }) else { continue }
            for item in combined.fnItems where !item.expectOCRUncertain {
                let flags = item.expectedMappingProblem ? " [expectedMappingProblem]" : ""
                recallFailures.append("\(report.file): \(item.id) fehlt (S. \(item.page + 1), \(item.category), »\(item.text)«\(flags))")
            }
        }
        gates.append(GateResult(
            label: "(b) Sperrliste+Regeln finden jede sichtbare, erwartbare Identifikator-Stelle",
            passed: recallFailures.isEmpty, skipped: false, failures: recallFailures))

        // (c) zero clinical false positives for rules+blocklist.
        let clinicalFailures = reports.flatMap { report -> [String] in
            guard let combined = report.methods.first(where: { $0.key == "combined" }) else { return [] }
            return combined.clinicalHits.map {
                "\(report.file): S. \($0.page + 1) Fundstelle »\($0.finding.text)« (\($0.finding.origin), \($0.finding.category)) überlappt Pflichtinhalt »\($0.mustPreserveText)«"
            }
        }
        gates.append(GateResult(
            label: "(c) Keine klinischen Fehlalarme durch Sperrliste+Regeln (B05)",
            passed: clinicalFailures.isEmpty, skipped: false, failures: clinicalFailures))

        // (d) F09 has zero rules+blocklist findings.
        let f09 = reports.first { $0.file.hasPrefix("F09") }
        if let f09 {
            var failures: [String] = []
            if let error = f09.error {
                failures.append("\(f09.file): Analyse fehlgeschlagen (\(error))")
            } else {
                let findings = f09.methods.first(where: { $0.key == "combined" })?.findingCount ?? -1
                if findings != 0 {
                    failures.append("\(f09.file): \(findings) Fundstelle(n) gefunden, erwartet 0")
                }
            }
            gates.append(GateResult(
                label: "(d) Fehlalarmkontrolle F09 ohne Fundstellen (Sperrliste+Regeln)",
                passed: failures.isEmpty, skipped: false, failures: failures))
        } else {
            gates.append(GateResult(
                label: "(d) Fehlalarmkontrolle F09 ohne Fundstellen (Sperrliste+Regeln)",
                passed: true, skipped: true,
                failures: ["F09 nicht in der Auswahl (--only) – Prüfung übersprungen"]))
        }
        return gates
    }

    // MARK: Markdown rendering

    private static func renderMarkdown(environment: EnvironmentInfo,
                                       annotations: FixtureAnnotationFile,
                                       blocklist: Blocklist,
                                       options: ReportOptions,
                                       reports: [DocReport],
                                       gates: [GateResult]) -> String {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }

        add("# PaperVeil – Qualitätsbericht Erkennung (`pv-eval report`)")
        add("")
        add("- **Datum:** \(environment.date)")
        add("- **Git-Commit:** `\(environment.gitCommit)`")
        add("- **Betriebssystem:** \(environment.macOS)")
        add("- **Werkzeugkette:** \(environment.swiftVersion)")
        add("- **Testsatz:** \(options.fixturesDir.path) – Schema-Version \(annotations.schemaVersion), Generator \(annotations.generator), logisches Fixturedatum \(annotations.contentDate)")
        add("- **Sperrliste:** `\(options.fixturesDir.appendingPathComponent("blocklist.json").path)` – \(blocklist.entries.count) fiktive Einträge")
        if let llm = options.llm {
            add("- **LLM:** **echter lokaler LM-Studio-Lauf** – Modell-ID `\(llm.model)` (validiert gegen `/v1/models`), Endpunkt \(llm.endpoint), Timeout \(llm.timeoutSeconds) s je Seite; Läufe sequenziell, Latenz je Seite gemessen")
        } else {
            add("- **LLM:** nicht ausgeführt (kein `--llm-model` angegeben)")
        }
        if !options.only.isEmpty {
            add("- **Auswahl:** Teilmenge `--only \(options.only.joined(separator: ","))` – Gate-Aussagen gelten nur für diese Auswahl")
        }
        add("")
        add("> **Ergebnisse gelten nur für diesen synthetischen Testsatz und sind keine allgemeine Erkennungsquote.**")
        add("")

        // Gate summary
        add("## Pflicht-Regressionssatz (Gate)")
        add("")
        add("| Regel | Ergebnis |")
        add("|---|---|")
        for gate in gates {
            let symbol = gate.skipped ? "übersprungen" : (gate.passed ? "bestanden" : "**FEHLGESCHLAGEN**")
            add("| \(gate.label) | \(symbol) |")
        }
        add("")
        for gate in gates where !gate.passed && !gate.skipped {
            add("**Verletzungen – \(gate.label):**")
            for failure in gate.failures { add("- \(failure)") }
            add("")
        }

        // Input validation table
        add("## Eingabeprüfung (alle Dokumente)")
        add("")
        add("| Dokument | erwartet | tatsächlich | Ergebnis |")
        add("|---|---|---|---|")
        for report in reports {
            let ok = report.expectedOutcome == report.actualOutcome
            add("| `\(report.file)` | \(report.expectedOutcome) | \(report.actualOutcome) | \(ok ? "✓" : "**✗**") |")
        }
        add("")

        // Category lookup for aggregation
        let categoryOf: [String: String] = {
            var map: [String: String] = [:]
            for document in annotations.documents {
                for identifier in document.identifiers { map[identifier.id] = identifier.category }
            }
            return map
        }()
        // Visible target counts per category over the selected documents.
        let selectedFiles = Set(reports.map(\.file))
        var targetsByCategory: [String: Int] = [:]
        for document in annotations.documents where selectedFiles.contains(document.file) {
            for identifier in document.identifiers where identifier.isVisibleTarget {
                targetsByCategory[identifier.category, default: 0] += 1
            }
        }

        let methodOrder: [(key: String, display: String)] = [
            ("blocklist", "Sperrliste (blocklist.json)"),
            ("rules", "Regeln (RuleDetector)"),
            ("combined", "Kombiniert (Sperrliste+Regeln, wie die Pipeline)"),
        ]

        func methodTable(key: String, display: String) {
            add("### \(display)")
            add("")
            var tpByCategory: [String: Int] = [:]
            var fnByCategory: [String: Int] = [:]
            var fpByCategory: [String: Int] = [:]
            var tpTotal = 0, fnTotal = 0, fpTotal = 0
            for report in reports {
                guard let method = report.methods.first(where: { $0.key == key }) else { continue }
                for id in method.tpIDs {
                    let category = categoryOf[id] ?? "other"
                    tpByCategory[category, default: 0] += 1
                    tpTotal += 1
                }
                for item in method.fnItems {
                    fnByCategory[item.category, default: 0] += 1
                    fnTotal += 1
                }
                for item in method.fpItems {
                    fpByCategory[item.category, default: 0] += 1
                    fpTotal += 1
                }
            }
            let categories = Array(Set(targetsByCategory.keys)
                .union(tpByCategory.keys).union(fnByCategory.keys).union(fpByCategory.keys))
                .sorted()
            add("| Kategorie | TP | FN | FP | TP/Anzahl* |")
            add("|---|---:|---:|---:|---|")
            for category in categories {
                let tp = tpByCategory[category] ?? 0
                let fn = fnByCategory[category] ?? 0
                let fp = fpByCategory[category] ?? 0
                let targets = targetsByCategory[category] ?? 0
                let ratio = targets > 0 ? "\(tp)/\(targets)" : "–"
                add("| \(category) | \(tp) | \(fn) | \(fp) | \(ratio) |")
            }
            let targetsAll = targetsByCategory.values.reduce(0, +)
            add("| **Gesamt** | **\(tpTotal)** | **\(fnTotal)** | **\(fpTotal)** | **\(targetsAll > 0 ? "\(tpTotal)/\(targetsAll)" : "–")** |")
            add("")
            add("\\* Quote nur für diesen Testsatz, keine allgemeine Erkennungsquote.")
            add("")
        }

        add("## Metriken je Verfahren und Kategorie (Rohzählungen)")
        add("")
        for method in methodOrder { methodTable(key: method.key, display: method.display) }
        if options.llm != nil {
            methodTable(key: "llm", display: "LLM (\(options.llm!.model), echter lokaler LM-Studio-Lauf)")
            methodTable(key: "combined_llm", display: "Kombiniert (Sperrliste+Regeln+LLM)")
        }

        // Per-document details
        add("## Details je Dokument")
        add("")
        for report in reports {
            add("### `\(report.file)` (\(report.expectedOutcome))")
            add("")
            add("- Eingabe: **\(report.actualOutcome)** – \(report.inputDetail) \(report.expectedOutcome == report.actualOutcome ? "✓" : "**✗**")")
            if let error = report.error {
                add("- **Fehler:** \(error)")
                add("")
                continue
            }
            guard report.analysisRan else { add(""); continue }
            add("- Seiten: \(report.pageCount); Extraktions-Warnungen: \(report.extractionWarnings.isEmpty ? "keine" : "")")
            for warning in report.extractionWarnings { add("  - \(warning)") }
            var summaryParts: [String] = []
            for method in report.methods {
                summaryParts.append("\(method.displayName): \(method.findingCount) Fundstellen (TP \(method.tpIDs.count), FN \(method.fnItems.count), FP \(method.fpItems.count))")
            }
            for part in summaryParts { add("- \(part)") }

            for method in report.methods {
                if !method.fnItems.isEmpty {
                    add("- **FN \(method.displayName):**")
                    for item in method.fnItems {
                        var flags: [String] = []
                        if item.expectOCRUncertain { flags.append("OCR unsicher erwartet") }
                        if item.expectedMappingProblem { flags.append("Zuordnungsproblem erwartet") }
                        let flagText = flags.isEmpty ? "" : " – Kennzeichnung: \(flags.joined(separator: ", "))"
                        add("  - \(item.id) (S. \(item.page + 1), \(item.category)): »\(item.text)«\(flagText)")
                    }
                }
                if !method.fpItems.isEmpty {
                    add("- **FP \(method.displayName):**")
                    for item in method.fpItems {
                        add("  - S. \(item.page + 1), \(item.category), \(item.origin): »\(item.text)«")
                    }
                }
                if !method.clinicalHits.isEmpty {
                    add("- **Klinische Fehlalarme \(method.displayName) (B05):**")
                    for hit in method.clinicalHits {
                        add("  - S. \(hit.page + 1): Fundstelle »\(hit.finding.text)« (\(hit.finding.origin)) überlappt »\(hit.mustPreserveText)«")
                    }
                }
                if !method.hiddenHits.isEmpty {
                    add("- Fundstellen auf versteckte/manuelle Annotationen (\(method.displayName)): \(method.hiddenHits.count)")
                }
            }

            if !report.hiddenIdentifiers.isEmpty {
                add("- **Versteckte Identifikatoren (keine Erkennungsziele, abgedeckt durch Export, C04):**")
                for item in report.hiddenIdentifiers {
                    add("  - \(item.id) (S. \(item.page + 1), \(item.category), Kanal \(item.channel ?? "?")): »\(item.text)«")
                }
            }
            if !report.manualIdentifiers.isEmpty {
                add("- **Manuell zu schwärzen (manualOnly):**")
                for item in report.manualIdentifiers {
                    add("  - \(item.id) (S. \(item.page + 1), \(item.category)): »\(item.text)«")
                }
            }
            if !report.unlocatedMustPreserve.isEmpty {
                add("- **Nicht im Seitentext lokalisierbare mustPreserve-Einträge:** \(report.unlocatedMustPreserve.map { "»\($0)«" }.joined(separator: ", "))")
            }
            if let pages = report.llmPages {
                add("- **LLM je Seite (echter lokaler LM-Studio-Lauf):**")
                add("")
                add("  | Seite | Latenz (s) | Fundstellen | Warnungen |")
                add("  |---|---:|---:|---|")
                for page in pages {
                    let warnings = page.warnings.isEmpty
                        ? "–"
                        : page.warnings.sorted { $0.key < $1.key }
                            .map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
                    add("  | \(page.page + 1) | \(String(format: "%.1f", page.latencySeconds)) | \(page.findings) | \(warnings) |")
                }
                add("")
            }
            add("")
        }

        add("## Einordnung und bekannte Grenzen")
        add("")
        add("- Der Testsatz ist synthetisch und vollständig fiktiv; er beweist nur das Verhalten an diesen Fällen (siehe `docs/ZIELZUSTAND.md`, Abschnitt 5).")
        add("- Versteckte Identifikatoren (Metadaten, Formulare, Annotationen, Anhänge, unsichtbarer Text, außerhalb der CropBox) sind keine Erkennungsziele und werden durch den Raster-Export entfernt (C04); sie werden oben separat aufgeführt.")
        add("- Absenderdaten (Klinik/Praxis/Arzt) sind in diesem Testsatz bewusst **nicht** als Identifikatoren annotiert (`policy.clinicAndPhysicianDataIsIdentifier: false`); Fundstellen darauf werden als FP gezählt und separat ausgewiesen.")
        if options.llm == nil {
            add("- LLM-Erkennung: **nicht ausgeführt** – dieser Bericht umfasst nur Sperrliste und Regeln.")
        } else {
            add("- LLM-Erkennung: **echter lokaler LM-Studio-Lauf** (nicht simuliert, nicht Teil des Gates; Modellausgabe ist nicht deterministisch).")
        }
        add("")
        return lines.joined(separator: "\n")
    }
}

// MARK: - JSON payload

struct ReportMeta: Codable, Sendable {
    var generated: String
    var gitCommit: String
    var macOS: String
    var swiftVersion: String
    var fixturesSchemaVersion: Int
    var blocklistEntries: Int
    var llmModel: String?
    var llmEndpoint: String?
    var llmTimeoutSeconds: Double?
}

struct ReportJSON: Codable, Sendable {
    var meta: ReportMeta
    var gates: [GateResult]
    var documents: [DocReport]
}
