import AppKit
import Foundation
import PaperVeilCore

// pv-fixtures – deterministischer Generator des synthetischen PaperVeil-Testsatzes.
//
// Aufruf:  swift run pv-fixtures [AusgabeVerzeichnis]
// Standard: Fixtures/synthetic
//
// Erzeugt 12 PDFs (F01–F09, F10a/b/c), annotations.json und führt nach dem
// Schreiben eine Selbstprüfung aus (PDFKit/CGPDFDocument): Jeder Text-PDF-
// Identifikator muss im Seiteninhalt auffindbar sein und sein annotiertes Rect
// muss die PDFKit-Auswahlgeometrie schneiden. Bei Fehlern Exit-Status != 0.

let args = CommandLine.arguments
let outputDirArg = args.count > 1 ? args[1] : "Fixtures/synthetic"
let outputDir = URL(fileURLWithPath: outputDirArg, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

// MARK: - Build all fixtures

func buildAll() throws -> [(DocumentAnnotation, [VerifyItem])] {
    var results: [(DocumentAnnotation, [VerifyItem])] = []
    func build(_ name: String, _ make: (URL) throws -> (DocumentAnnotation, [VerifyItem])) throws {
        let url = outputDir.appendingPathComponent(name)
        results.append(try make(url))
    }
    try build("F01-arztbrief.pdf", buildF01)
    try build("F02-laborblatt.pdf", buildF02)
    try build("F03-medikationsplan.pdf", buildF03)
    try build("F04-scan.pdf", buildF04)
    try build("F05-rotation-beschnitt.pdf", buildF05)
    try build("F06-gemischt.pdf", buildF06)
    try build("F07-versteckt.pdf", buildF07)
    try build("F08-schlechter-scan.pdf", buildF08)
    try build("F09-ohne-identifikatoren.pdf", buildF09)
    try build("F10a-beschaedigt.pdf", buildF10a)
    try build("F10b-verschluesselt.pdf", buildF10b)
    try build("F10c-manipulativ.pdf", buildF10c)
    return results
}

func writeAnnotations(_ documents: [DocumentAnnotation]) throws {
    let file = AnnotationFile(
        schemaVersion: 1,
        generator: "pv-fixtures",
        contentDate: Fiction.contentDate,
        policy: FixturePolicy(
            statement: "Alle Personen, Adressen, Telefonnummern, KV-Nummern, E-Mail-Adressen und Institutionen in diesem Testsatz sind frei erfunden („Mustermann“-Platzhalter). Es liegen keine echten Befunde oder Patientendaten vor.",
            patientDataIsIdentifier: true,
            clinicAndPhysicianDataIsIdentifier: false,
            annotationSpace: "Unrotated mediaBox page space, Punkt, Ursprung unten links (PageRect-Konvention aus PaperVeilCore).",
            footer: Fiction.footer),
        documents: documents)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(file)
    try data.write(to: outputDir.appendingPathComponent("annotations.json"), options: .atomic)
}

func reportSizes() throws {
    let fm = FileManager.default
    let items = try fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.fileSizeKey])
        .filter { $0.pathExtension == "pdf" || $0.lastPathComponent == "annotations.json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var total = 0
    print("Erzeugte Dateien:")
    for item in items {
        let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        total += size
        print(String(format: "  %-32s %8d Bytes", (item.lastPathComponent as NSString).utf8String!, size))
    }
    print(String(format: "  %-32s %8d Bytes", ("GESAMT" as NSString).utf8String!, total))
}

// MARK: - Run

func run() -> Int32 {
    do {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDir.path) {
            try fm.removeItem(at: outputDir)
        }
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        print("Erzeuge Testsatz in \(outputDir.path) …")
        let built = try buildAll()

        var documents: [DocumentAnnotation] = []
        for (ann, _) in built { documents.append(ann) }
        try writeAnnotations(documents)

        // Self-check: every fixture must satisfy its recorded expectations.
        print("Selbstprüfung mit PDFKit/CGPDFDocument …")
        var allErrors: [String] = []
        for (ann, checks) in built {
            let url = outputDir.appendingPathComponent(ann.file)
            var items = checks
            // Datenschutz: PDFKit trägt sonst den echten macOS-Benutzernamen in
            // Annotationen ein. Kein echtes Namensfragment darf im Testsatz landen.
            let realName = NSFullUserName()
            if !realName.isEmpty {
                items.append(.privacyScan(string: realName, label: "echter macOS-Benutzername"))
            }
            let realShort = NSUserName()
            if !realShort.isEmpty, realShort != realName {
                items.append(.privacyScan(string: realShort, label: "echter macOS-Kurzbenutzername"))
            }
            var verifier = Verifier(file: ann.file)
            verifier.run(url: url, items: items, password: ann.password)
            allErrors.append(contentsOf: verifier.errors)
        }
        for e in allErrors where e.contains("wie erwartet") {
            print("  INFO: \(e)")
        }
        let failures = allErrors.filter { !$0.contains("wie erwartet") }
        if !failures.isEmpty {
            print(FixtureError.verificationFailed(failures))
            return 1
        }
        print("Selbstprüfung bestanden (\(built.count) Dokumente).")
        try reportSizes()
        return 0
    } catch {
        print("Fehler: \(error)")
        return 1
    }
}

exit(run())
