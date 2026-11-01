import Foundation
import PaperVeilDetection
import PaperVeilExtraction

let usage = """
pv-eval – Evaluations- und Audit-CLI von PaperVeil (Zielzustand B06, C02–C05)

Verwendung:
  pv-eval report --fixtures <dir> --out <datei.md> [--json <datei.json>]
                 [--llm-model <id>] [--llm-endpoint http://127.0.0.1:1234]
                 [--llm-timeout 300] [--only F01,F10c]
  pv-eval export-audit --fixtures <dir> --out <datei.md> [--work <dir>]
                        [--dpi 300] [--only F01]

  report        Misst je Erkennungsverfahren (Sperrliste, Regeln, optional echtes
                lokales LLM) und Kategorie Treffer, übersehene Stellen und
                Fehlalarme gegen den annotierten Testsatz und prüft den
                Pflicht-Regressionssatz (Exit 1 bei Verletzung).
  export-audit  Exportiert jedes gültige Dokument über die geteilte Pipeline mit
                simulierter Freigabe und prüft den Export unabhängig
                (Originalschutz, tatsächliche Entfernung, Nebenkanäle, Qualität).
"""

struct ParsedArguments {
    var values: [String: String] = [:]
    var unknown: [String] = []
}

func parseArguments(_ args: [String], optionsNeedingValue: [String]) -> ParsedArguments {
    var parsed = ParsedArguments()
    var i = 0
    while i < args.count {
        let token = args[i]
        if token.hasPrefix("--"), let equals = token.firstIndex(of: "=") {
            let name = String(token[..<equals])
            let value = String(token[token.index(after: equals)...])
            if optionsNeedingValue.contains(name) {
                parsed.values[name] = value
            } else {
                parsed.unknown.append(token)
            }
            i += 1
        } else if token.hasPrefix("--") {
            guard i + 1 < args.count, optionsNeedingValue.contains(token) else {
                parsed.unknown.append(token)
                i += 1
                continue
            }
            parsed.values[token] = args[i + 1]
            i += 2
        } else {
            parsed.unknown.append(token)
            i += 1
        }
    }
    return parsed
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
let subcommand = args.first ?? ""
let rest = Array(args.dropFirst())

if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
    print(usage)
    exit(0)
}

if subcommand == "report" {
    let parsed = parseArguments(rest, optionsNeedingValue: [
        "--fixtures", "--out", "--json", "--llm-model", "--llm-endpoint", "--llm-timeout", "--only"])
    guard parsed.unknown.isEmpty else { fail("Unbekannte Argumente: \(parsed.unknown.joined(separator: " "))") }
    guard let fixtures = parsed.values["--fixtures"] else { fail("--fixtures fehlt.") }
    guard let out = parsed.values["--out"] else { fail("--out fehlt.") }

    let llmModel = parsed.values["--llm-model"]
    let endpointString = parsed.values["--llm-endpoint"] ?? "http://127.0.0.1:1234"
    let timeout = Double(parsed.values["--llm-timeout"] ?? "300") ?? 300
    let only = (parsed.values["--only"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }

    var llm: LLMRunConfig? = nil
    if let model = llmModel {
        let endpoint: LMStudioEndpoint
        do {
            endpoint = try LMStudioEndpoint(string: endpointString)
        } catch {
            fail("Ungültiger --llm-endpoint: \(error)")
        }
        llm = LLMRunConfig(endpoint: endpoint, model: model, timeoutSeconds: timeout)
    }

    let options = ReportOptions(
        fixturesDir: URL(fileURLWithPath: fixtures),
        outURL: URL(fileURLWithPath: out),
        jsonURL: parsed.values["--json"].map { URL(fileURLWithPath: $0) },
        llm: llm,
        only: only)
    exit(await ReportCommand.run(options))
}

if subcommand == "ocr-probe" {
    let ok = await OCRCompute.isAvailable()
    print(ok ? "Vision-OCR verfügbar" : "Vision-OCR auf dieser Maschine NICHT verfügbar")
    exit(ok ? 0 : 1)
}

if subcommand == "export-audit" {
    let parsed = parseArguments(rest, optionsNeedingValue: ["--fixtures", "--out", "--work", "--dpi", "--only"])
    guard parsed.unknown.isEmpty else { fail("Unbekannte Argumente: \(parsed.unknown.joined(separator: " "))") }
    guard let fixtures = parsed.values["--fixtures"] else { fail("--fixtures fehlt.") }
    guard let out = parsed.values["--out"] else { fail("--out fehlt.") }
    let dpi = Double(parsed.values["--dpi"] ?? "300") ?? 300
    let only = (parsed.values["--only"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    let workRoot: URL
    if let work = parsed.values["--work"] {
        workRoot = URL(fileURLWithPath: work)
    } else {
        workRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pv-eval-export-audit-\(UUID().uuidString.prefix(8))")
    }
    let options = ExportAuditOptions(
        fixturesDir: URL(fileURLWithPath: fixtures),
        outURL: URL(fileURLWithPath: out),
        workRoot: workRoot,
        dpi: dpi,
        only: only)
    exit(await ExportAuditCommand.run(options))
}

fail("Unbekannter Unterbefehl: \(subcommand.isEmpty ? "(keiner)" : subcommand)")
