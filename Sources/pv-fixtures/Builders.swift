import Foundation
import PaperVeilCore

// MARK: - Per-document accumulator (annotations + self-check items)

/// Every occurrence of an identifier string on a page is annotated, so the
/// occurrence index can be derived automatically from the order in which the
/// builder records identifiers on a page.
final class Fixture {
    var ann: DocumentAnnotation
    var checks: [VerifyItem] = []
    private var occurrences: [String: Int] = [:]

    init(file: String, kind: FixtureKind, outcome: FixtureOutcome,
         password: String? = nil, notes: String? = nil) {
        ann = DocumentAnnotation(file: file, kind: kind, expectedInputOutcome: outcome,
                                 password: password, pageCount: 0, pageRotations: [],
                                 notes: notes, identifiers: [], mustPreserve: [])
    }

    func finish(pageCount: Int, rotations: [Int]) -> (DocumentAnnotation, [VerifyItem]) {
        ann.pageCount = pageCount
        ann.pageRotations = rotations
        return (ann, checks)
    }

    // MARK: identifiers

    /// A visible or invisible identifier inside the *page text*. Occurrence is
    /// auto-derived from previously recorded identifiers with the same text on
    /// the same page (the builder must annotate every occurrence).
    /// `expectExtractable: false` skips the pageText check for identifiers that
    /// PDFKit deliberately does not extract (e.g. outside the crop box).
    func identifier(page: Int, id: String, text: String, category: IdentifierCategory,
                     rects: [CGRect], hidden: Bool = false, channel: FixtureChannel? = nil,
                     ocrUncertain: Bool = false, mappingProblem: Bool = false,
                     expectExtractable: Bool = true, note: String? = nil) {
        let key = "\(page)|\(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))"
        let occurrence = occurrences[key] ?? 0
        occurrences[key] = occurrence + 1
        ann.identifiers.append(IdentifierAnnotation(
            id: id, pageIndex: page, text: text, category: category.rawValue,
            rects: rects.map { rounded($0) }, occurrence: occurrence,
            hidden: hidden, channel: channel, manualOnly: false,
            expectOCRUncertain: ocrUncertain, expectedMappingProblem: mappingProblem, note: note))
        if expectExtractable {
            checks.append(.pageText(page: page, needle: text, occurrence: occurrence,
                                   rects: rects, note: note ?? id))
        }
    }

    /// An identifier in a non-page channel (metadata, form field, annotation,
    /// attachment). No occurrence, rects may be empty.
    func channelIdentifier(page: Int, id: String, text: String, category: IdentifierCategory,
                           channel: FixtureChannel, rects: [CGRect] = [],
                           note: String? = nil) {
        ann.identifiers.append(IdentifierAnnotation(
            id: id, pageIndex: page, text: text, category: category.rawValue,
            rects: rects.map { rounded($0) }, occurrence: nil,
            hidden: true, channel: channel, manualOnly: false,
            expectOCRUncertain: false, expectedMappingProblem: false, note: note))
    }

    /// A visible identifier on a scan page (no text layer; pixel check only).
    func scanIdentifier(page: Int, id: String, text: String, category: IdentifierCategory,
                        rects: [CGRect], ocrUncertain: Bool = false,
                        mappingProblem: Bool = false, pixelThreshold: Int = 140,
                        note: String? = nil) {
        ann.identifiers.append(IdentifierAnnotation(
            id: id, pageIndex: page, text: text, category: category.rawValue,
            rects: rects.map { rounded($0) }, occurrence: nil,
            hidden: false, channel: nil, manualOnly: false,
            expectOCRUncertain: ocrUncertain, expectedMappingProblem: mappingProblem,
            note: note))
        for (i, r) in rects.enumerated() {
            checks.append(.darkPixels(page: page, rect: r, label: "\(id) rect\(i) (\(text))",
                                      threshold: pixelThreshold))
        }
    }

    /// A manually redactable area without text semantics (e.g. QR code).
    func manualRegion(page: Int, id: String, text: String, category: IdentifierCategory,
                      rect: CGRect, note: String? = nil) {
        ann.identifiers.append(IdentifierAnnotation(
            id: id, pageIndex: page, text: text, category: category.rawValue,
            rects: [rounded(rect)], occurrence: nil,
            hidden: false, channel: nil, manualOnly: true,
            expectOCRUncertain: false, expectedMappingProblem: false, note: note))
        checks.append(.darkPixels(page: page, rect: rect, label: "\(id) (\(text))"))
    }

    // MARK: must-preserve

    func mustPreserve(page: Int, _ text: String, note: String? = nil) {
        ann.mustPreserve.append(MustPreserveAnnotation(pageIndex: page, text: text,
                                                       rect: nil, note: note))
        checks.append(.mustPreserveText(page: page, needle: text))
    }

    func mustPreserveScan(page: Int, _ text: String, rect: CGRect,
                          pixelThreshold: Int = 140, note: String? = nil) {
        ann.mustPreserve.append(MustPreserveAnnotation(pageIndex: page, text: text,
                                                       rect: rounded(rect), note: note))
        checks.append(.darkPixels(page: page, rect: rect, label: "mustPreserve \(text)",
                                  threshold: pixelThreshold))
    }

    /// Synthetic footer on a text page.
    func footerCheck(page: Int) {
        checks.append(.pageText(page: page, needle: Fiction.footer, occurrence: 0,
                               rects: [], note: "Synthetic footer"))
    }

    /// Synthetic footer on a scan page (pixel check).
    func footerCheckScan(page: Int, rect: CGRect, threshold: Int = 140) {
        checks.append(.darkPixels(page: page, rect: rect, label: "Synthetic footer", threshold: threshold))
    }

    func noTextLayer(page: Int) {
        checks.append(.noTextLayer(page: page))
    }

    func rounded(_ r: CGRect) -> PageRect {
        PageRect(x: (r.origin.x * 100).rounded() / 100,
                 y: (r.origin.y * 100).rounded() / 100,
                 width: (r.size.width * 100).rounded() / 100,
                 height: (r.size.height * 100).rounded() / 100)
    }
}

// MARK: - Shared layout pieces

/// Fictional clinic letterhead (sender data — deliberately NOT annotated as
/// patient identifiers; see policy in annotations.json).
func drawLetterhead(_ doc: PDFDoc) {
    _ = doc.draw(Fiction.clinicName, font: .helveticaBold(14), at: CGPoint(x: 60, y: 800))
    _ = doc.draw(Fiction.clinicDepartment, font: .helvetica(10), at: CGPoint(x: 60, y: 783))
    _ = doc.draw("\(Fiction.clinicStreet) · 23456 Beispielhafen", font: .helvetica(9), at: CGPoint(x: 60, y: 767))
    _ = doc.draw("Tel. \(Fiction.clinicPhone) · \(Fiction.clinicEmail)", font: .helvetica(9), at: CGPoint(x: 60, y: 754))
    doc.rule(from: CGPoint(x: 60, y: 745), to: CGPoint(x: 535, y: 745))
}

func pad(_ s: String, to n: Int) -> String {
    var r = s
    while r.count < n { r += " " }
    return String(r.prefix(n))
}

// MARK: - F01: multi-page Arztbrief

func buildF01(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F01-arztbrief.pdf", kind: .text, outcome: .ok,
                    notes: "Mehrseitiger Arztbrief mit wiederholtem Namen, Adresse, Geburtsdatum (geb.), KV-Nr., Telefon und E-Mail. Klinik- und Arztdaten (Absender) sind absichtlich nicht als Identifikatoren annotiert (siehe policy).")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))

    // ---------------- Page 1 ----------------
    doc.beginPage()
    drawLetterhead(doc)

    let addressX: CGFloat = 340
    let name1 = doc.draw(Fiction.patientName, font: .helvetica(11), at: CGPoint(x: addressX, y: 706))
    let street1 = doc.draw(Fiction.patientStreet, font: .helvetica(11), at: CGPoint(x: addressX, y: 690))
    let city1 = doc.draw(Fiction.patientCity, font: .helvetica(11), at: CGPoint(x: addressX, y: 674))
    let birth1 = doc.draw("geb. \(Fiction.patientBirth)", font: .helvetica(11), at: CGPoint(x: addressX, y: 658))
    let kv1 = doc.draw("KV-Nr.: \(Fiction.patientKVNR)", font: .helvetica(11), at: CGPoint(x: addressX, y: 642))
    let tel1 = doc.draw("Tel.: \(Fiction.patientPhone)", font: .helvetica(11), at: CGPoint(x: addressX, y: 626))
    let mail1 = doc.draw("E-Mail: \(Fiction.patientEmail)", font: .helvetica(9), at: CGPoint(x: addressX, y: 611))

    let pid1 = doc.draw("Patienten-ID: \(Fiction.patientNumber)", font: .helvetica(10), at: CGPoint(x: 60, y: 706))
    _ = doc.draw("Beispielhafen, den \(Fiction.letterDate)", font: .helvetica(10), at: CGPoint(x: 60, y: 686))

    _ = doc.draw("Arztbrief über den stationären Aufenthalt", font: .helveticaBold(13), at: CGPoint(x: 60, y: 648))

    var y: CGFloat = 622
    let body1: [(String, CGFloat)] = [
        ("Sehr geehrte Frau Mustermann,", 1.6),
        ("wir berichten über den stationären Aufenthalt von Frau", 1.0),
        ("Erika Mustermann in unserer Klinik vom 20.01.2026 bis", 1.0),
        ("02.02.2026. Anlass war eine instabile Stoffwechsellage", 1.0),
        ("bei bekanntem Diabetes mellitus Typ 2.", 1.6),
        ("Bei Aufnahme zeigte sich ein Nüchternblutdruck von 142/86", 1.0),
        ("mmHg, das HbA1c lag bei 7,8 %. Das Kreatinin betrug 0,9", 1.0),
        ("mg/dl, das Natrium 139 mmol/l. Der Base Excess war mit", 1.0),
        ("-2,4 mmol/l leicht erniedrigt.", 1.0),
    ]
    var bodyLines: [PlacedLine] = []
    for (line, gap) in body1 {
        bodyLines.append(doc.draw(line, font: .helvetica(11), at: CGPoint(x: 60, y: y)))
        y -= 15 * gap
    }
    doc.drawFooter()
    doc.endPage()

    // Identifiers, page 0 (in drawing order = extraction order).
    f.identifier(page: 0, id: "F01-01", text: Fiction.patientName, category: .name,
                 rects: [name1.rect], note: "Patientenblock")
    f.identifier(page: 0, id: "F01-02", text: "\(Fiction.patientStreet)\n\(Fiction.patientCity)",
                 category: .address, rects: [street1.rect, city1.rect],
                 note: "Adresse über zwei Zeilen")
    f.identifier(page: 0, id: "F01-03", text: Fiction.patientBirth, category: .birthDate,
                 rects: [birth1.rect(of: Fiction.patientBirth)], note: "mit „geb.“ markiert")
    f.identifier(page: 0, id: "F01-04", text: Fiction.patientKVNR, category: .insuranceNumber,
                 rects: [kv1.rect(of: Fiction.patientKVNR)])
    f.identifier(page: 0, id: "F01-05", text: Fiction.patientPhone, category: .phone,
                 rects: [tel1.rect(of: Fiction.patientPhone)])
    f.identifier(page: 0, id: "F01-06", text: Fiction.patientEmail, category: .email,
                 rects: [mail1.rect(of: Fiction.patientEmail)])
    f.identifier(page: 0, id: "F01-07", text: Fiction.patientNumber, category: .patientID,
                 rects: [pid1.rect(of: Fiction.patientNumber)])
    f.identifier(page: 0, id: "F01-08", text: Fiction.patientName, category: .name,
                 rects: [bodyLines[2].rect(of: Fiction.patientName)], note: "im Fließtext")
    f.identifier(page: 0, id: "F01-09", text: "Frau Mustermann", category: .name,
                 rects: [bodyLines[0].rect(of: "Frau Mustermann")], note: "Anrede")
    f.footerCheck(page: 0)

    f.mustPreserve(page: 0, "142/86 mmHg", note: "Blutdruckwert mit Schrägstrich")
    f.mustPreserve(page: 0, "7,8 %", note: "Dezimalkomma")
    f.mustPreserve(page: 0, "0,9 mg/dl", note: "Dezimalkomma + Einheit")
    f.mustPreserve(page: 0, "139 mmol/l", note: "Einheit")
    f.mustPreserve(page: 0, "-2,4 mmol/l", note: "negativer Wert")
    f.mustPreserve(page: 0, "20.01.2026 bis", note: "klinisches Datum (Aufnahme)")
    f.mustPreserve(page: 0, "02.02.2026", note: "klinisches Datum (Entlassung)")

    // ---------------- Page 2 ----------------
    doc.beginPage()
    _ = doc.draw("Verlauf", font: .helveticaBold(13), at: CGPoint(x: 60, y: 760))
    y = 732
    let body2: [(String, CGFloat)] = [
        ("Im Verlauf konnte die Blutzuckereinstellung schrittweise", 1.0),
        ("verbessert werden. Am 27.01.2026 wurde die Metformin-", 1.0),
        ("Dosis auf 2-mal 500 mg täglich erhöht.", 1.6),
        ("Unter der angepassten Therapie sank der Nüchternblutdruck", 1.0),
        ("auf 128/78 mmHg. Die Kontrolle am 01.02.2026 zeigte ein", 1.0),
        ("HbA1c von 7,2 %. Eine Hypoglykämie trat nicht auf.", 1.6),
        ("Frau Mustermann erhielt eine strukturierte Schulung zur", 1.0),
        ("Insulintherapie. Bei Frau Erika Mustermann wurde zudem", 1.0),
        ("eine Ernährungsumstellung eingeleitet.", 1.0),
    ]
    var body2Lines: [PlacedLine] = []
    for (line, gap) in body2 {
        body2Lines.append(doc.draw(line, font: .helvetica(11), at: CGPoint(x: 60, y: y)))
        y -= 15 * gap
    }
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 1, id: "F01-10", text: "Frau Mustermann", category: .name,
                 rects: [body2Lines[6].rect(of: "Frau Mustermann")], note: "Nachname im Fließtext")
    f.identifier(page: 1, id: "F01-11", text: Fiction.patientName, category: .name,
                 rects: [body2Lines[7].rect(of: Fiction.patientName)], note: "vollständiger Name im Fließtext")
    f.footerCheck(page: 1)
    f.mustPreserve(page: 1, "27.01.2026", note: "klinisches Datum")
    f.mustPreserve(page: 1, "500 mg", note: "Dosierung")
    f.mustPreserve(page: 1, "128/78 mmHg", note: "Blutdruck")
    f.mustPreserve(page: 1, "01.02.2026", note: "klinisches Datum")
    f.mustPreserve(page: 1, "7,2 %", note: "Dezimalkomma")

    // ---------------- Page 3 ----------------
    doc.beginPage()
    _ = doc.draw("Zusammenfassung und Empfehlung", font: .helveticaBold(13), at: CGPoint(x: 60, y: 760))
    y = 732
    let body3: [(String, CGFloat)] = [
        ("Die Patientin konnte bei stabilisierter Stoffwechsellage", 1.0),
        ("in deutlich gebessertem Allgemeinzustand entlassen werden.", 1.6),
        ("Wir empfehlen die Fortführung der aktuellen Medikation", 1.0),
        ("und eine labormedizinische Kontrolle in vier Wochen", 1.0),
        ("(Blutzucker, HbA1c, Nierenwerte).", 1.6),
        ("Frau Mustermann bitten wir, sich bei Unklarheiten in", 1.0),
        ("unserer Ambulanz zu melden.", 2.2),
        ("Mit freundlichen Grüßen", 2.2),
        ("Dr. med. Max Beispielmann", 1.0),
        ("Oberarzt, \(Fiction.clinicDepartment)", 1.0),
    ]
    var body3Lines: [PlacedLine] = []
    for (line, gap) in body3 {
        body3Lines.append(doc.draw(line, font: .helvetica(11), at: CGPoint(x: 60, y: y)))
        y -= 15 * gap
    }
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 2, id: "F01-12", text: "Frau Mustermann", category: .name,
                 rects: [body3Lines[5].rect(of: "Frau Mustermann")], note: "Nachname im Fließtext")
    f.footerCheck(page: 2)
    f.mustPreserve(page: 2, "Kontrolle in vier Wochen", note: "klinische Zeitangabe")
    f.mustPreserve(page: 2, "Blutzucker, HbA1c, Nierenwerte", note: "Kontrollparameter")

    doc.close()
    return f.finish(pageCount: 3, rotations: [0, 0, 0])
}

// MARK: - F02: Laborblatt

func buildF02(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F02-laborblatt.pdf", kind: .text, outcome: .ok,
                    notes: "Laborblatt mit 7,5-pt-Courier-Tabelle, Dezimalkommas, negativem Wert (Base Excess -2,4 mmol/l), Einheiten, Referenzbereichen und Flaggen. Einsender/Arztdaten sind nicht annotiert.")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))
    doc.beginPage()

    _ = doc.draw(Fiction.clinicName, font: .helveticaBold(12), at: CGPoint(x: 60, y: 800))
    _ = doc.draw("Zentrallabor", font: .helvetica(9), at: CGPoint(x: 60, y: 785))
    doc.rule(from: CGPoint(x: 60, y: 776), to: CGPoint(x: 535, y: 776))

    let p0 = doc.draw("Patientin: \(Fiction.patientName)    geb.: \(Fiction.patientBirth)",
                     font: .helvetica(9), at: CGPoint(x: 60, y: 758))
    _ = doc.draw("Einsender: \(Fiction.practiceName), \(Fiction.practiceStreet), \(Fiction.practiceCity)",
                 font: .helvetica(9), at: CGPoint(x: 60, y: 744))
    _ = doc.draw("Abnahme: 05.02.2026, 07:30 Uhr    Bericht: \(Fiction.letterDate)",
                 font: .helvetica(9), at: CGPoint(x: 60, y: 730))
    doc.rule(from: CGPoint(x: 60, y: 720), to: CGPoint(x: 535, y: 720))

    let rows: [(String, String, String, String, String)] = [
        ("Parameter", "Ergebnis", "Einheit", "Referenzbereich", "Fl"),
        ("Hämoglobin", "13,8", "g/dl", "12,0–15,5", ""),
        ("Hämatokrit", "41,2", "%", "37,0–47,0", ""),
        ("Leukozyten", "9,6", "/nl", "4,0–10,0", ""),
        ("Thrombozyten", "248", "/nl", "150–400", ""),
        ("Natrium", "139", "mmol/l", "136–145", ""),
        ("Kalium", "3,4", "mmol/l", "3,5–5,1", "!"),
        ("Kreatinin", "0,9", "mg/dl", "0,5–1,1", ""),
        ("Harnstoff", "38", "mg/dl", "17–43", ""),
        ("Base Excess", "-2,4", "mmol/l", "-2,0–3,0", "!"),
        ("Glukose", "88", "mg/dl", "70–100", ""),
        ("HbA1c", "7,8", "%", "<5,7", "(!)"),
    ]
    var y: CGFloat = 702
    var rowLines: [PlacedLine] = []
    for (i, row) in rows.enumerated() {
        let text = pad(row.0, to: 21) + pad(row.1, to: 10) + pad(row.2, to: 11)
            + pad(row.3, to: 16) + row.4
        let line = doc.draw(text, font: i == 0 ? .courierBold(7.5) : .courier(7.5),
                           at: CGPoint(x: 60, y: y))
        rowLines.append(line)
        y -= 11
    }
    _ = doc.draw("Bewertung: Die Werte entsprechen dem bekannten Verlauf. Kontrolle in vier Wochen.",
                 font: .helvetica(9), at: CGPoint(x: 60, y: y - 8))
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 0, id: "F02-01", text: Fiction.patientName, category: .name,
                 rects: [p0.rect(of: Fiction.patientName)], note: "Kopfzeile, 9 pt")
    f.identifier(page: 0, id: "F02-02", text: Fiction.patientBirth, category: .birthDate,
                 rects: [p0.rect(of: Fiction.patientBirth)], note: "Kopfzeile, 9 pt")
    f.footerCheck(page: 0)

    f.mustPreserve(page: 0, "13,8 g/dl", note: "Wert + Einheit (7,5 pt)")
    f.mustPreserve(page: 0, "41,2 %")
    f.mustPreserve(page: 0, "9,6 /nl")
    f.mustPreserve(page: 0, "248 /nl")
    f.mustPreserve(page: 0, "139 mmol/l")
    f.mustPreserve(page: 0, "3,4 mmol/l 3,5–5,1", note: "erniedrigter Wert mit Flagge")
    f.mustPreserve(page: 0, "0,9 mg/dl")
    f.mustPreserve(page: 0, "38 mg/dl")
    f.mustPreserve(page: 0, "Base Excess -2,4 mmol/l", note: "negativer Wert")
    f.mustPreserve(page: 0, "-2,0–3,0", note: "Referenzbereich mit Minus")
    f.mustPreserve(page: 0, "88 mg/dl")
    f.mustPreserve(page: 0, "7,8 %")
    f.mustPreserve(page: 0, "<5,7")
    f.mustPreserve(page: 0, "05.02.2026, 07:30 Uhr", note: "klinische Datumsangabe (kein Geburtsdatum)")

    doc.close()
    return f.finish(pageCount: 1, rotations: [0])
}

// MARK: - F03: Medikationsplan

func buildF03(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F03-medikationsplan.pdf", kind: .text, outcome: .ok,
                    notes: "Medikationsplan mit Dosierungen (1-0-1, 500 mg, 0-0-1/2), Startdaten und klinisch relevanten Verneinungen (Keine Penicillinallergie bekannt / Kein Marcumar).")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))
    doc.beginPage()

    _ = doc.draw("Medikationsplan", font: .helveticaBold(14), at: CGPoint(x: 60, y: 790))
    let p0 = doc.draw("Patientin: \(Fiction.patientName)", font: .helvetica(10), at: CGPoint(x: 60, y: 766))
    let p1 = doc.draw("geb.: \(Fiction.patientBirth)    Pat.-Nr.: \(Fiction.patientNumber)",
                     font: .helvetica(10), at: CGPoint(x: 60, y: 750))
    _ = doc.draw("Erstellt am \(Fiction.letterDate), \(Fiction.clinicName)",
                 font: .helvetica(10), at: CGPoint(x: 60, y: 734))
    doc.rule(from: CGPoint(x: 60, y: 724), to: CGPoint(x: 535, y: 724))

    let rows: [(String, String, String, String)] = [
        ("Medikament", "Dosis", "Schema", "Startdatum"),
        ("Metformin", "500 mg", "1-0-1", "15.01.2026"),
        ("ASS", "100 mg", "0-1-0", "02.02.2026"),
        ("L-Thyroxin", "75 µg", "0-0-1/2", "20.03.2026"),
        ("Torasemid", "10 mg", "1-0-0", "05.02.2026"),
    ]
    var y: CGFloat = 704
    for (i, row) in rows.enumerated() {
        let text = pad(row.0, to: 20) + pad(row.1, to: 11) + pad(row.2, to: 11) + row.3
        _ = doc.draw(text, font: i == 0 ? .courierBold(8) : .courier(8), at: CGPoint(x: 60, y: y))
        y -= 12
    }
    y -= 12
    _ = doc.draw("Keine Penicillinallergie bekannt.", font: .helveticaBold(11), at: CGPoint(x: 60, y: y))
    y -= 16
    _ = doc.draw("Kein Marcumar.", font: .helveticaBold(11), at: CGPoint(x: 60, y: y))
    y -= 24
    _ = doc.draw("Hinweis: Einnahme der Tabletten zu den Mahlzeiten. Kontrolle des Blutzuckers "
                 + "zweimal wöchentlich.", font: .helvetica(10), at: CGPoint(x: 60, y: y))
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 0, id: "F03-01", text: Fiction.patientName, category: .name,
                 rects: [p0.rect(of: Fiction.patientName)])
    f.identifier(page: 0, id: "F03-02", text: Fiction.patientBirth, category: .birthDate,
                 rects: [p1.rect(of: Fiction.patientBirth)])
    f.identifier(page: 0, id: "F03-03", text: Fiction.patientNumber, category: .patientID,
                 rects: [p1.rect(of: Fiction.patientNumber)])
    f.footerCheck(page: 0)

    f.mustPreserve(page: 0, "500 mg", note: "Dosierung")
    f.mustPreserve(page: 0, "1-0-1", note: "Einnahmeschema")
    f.mustPreserve(page: 0, "100 mg")
    f.mustPreserve(page: 0, "0-1-0")
    f.mustPreserve(page: 0, "75 µg", note: "Mikrogramm-Dosierung")
    f.mustPreserve(page: 0, "0-0-1/2", note: "Schema mit halber Tablette")
    f.mustPreserve(page: 0, "10 mg")
    f.mustPreserve(page: 0, "1-0-0")
    f.mustPreserve(page: 0, "15.01.2026", note: "Startdatum (klinisch)")
    f.mustPreserve(page: 0, "20.03.2026", note: "Startdatum (klinisch)")
    f.mustPreserve(page: 0, "Keine Penicillinallergie bekannt.", note: "klinisch relevante Verneinung")
    f.mustPreserve(page: 0, "Kein Marcumar.", note: "klinisch relevante Verneinung")

    doc.close()
    return f.finish(pageCount: 1, rotations: [0])
}

// MARK: - F09: no identifiers (false-positive control)

func buildF09(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F09-ohne-identifikatoren.pdf", kind: .text, outcome: .ok,
                    notes: "Fehlalarmkontrolle: nur klinische Zahlen und Datumsangaben, keine direkten Identifikatoren. Erwartet: keine Fundstellen. Die Dokument-Nr. ist eine Vorgangsnummer und keine Personenkennung.")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))
    doc.beginPage()

    _ = doc.draw("Labor-Verlaufskontrolle", font: .helveticaBold(13), at: CGPoint(x: 60, y: 780))
    _ = doc.draw("Dokument-Nr.: B-2026-047", font: .helvetica(9), at: CGPoint(x: 60, y: 758))

    var y: CGFloat = 730
    let rows = [
        "Messung vom 05.01.2026: HbA1c 7,8 %, Kreatinin 0,9 mg/dl",
        "Messung vom 02.02.2026: HbA1c 7,2 %, Kreatinin 0,9 mg/dl",
        "Messung vom 05.02.2026: HbA1c 7,0 %, Kreatinin 0,8 mg/dl",
    ]
    for r in rows {
        _ = doc.draw(r, font: .courier(9), at: CGPoint(x: 60, y: y))
        y -= 14
    }
    y -= 10
    _ = doc.drawParagraph("Die Therapie wird fortgeführt. Eine Kontrolle ist in vier Wochen geplant. "
                          + "Blutdruckwerte: 142/86 mmHg (05.01.2026), 128/78 mmHg (05.02.2026). "
                          + "Der Base Excess betrug zuletzt -2,4 mmol/l.",
                          font: .helvetica(10), at: CGPoint(x: 60, y: y), maxWidth: 475, leading: 15)
    doc.drawFooter()
    doc.endPage()

    f.footerCheck(page: 0)
    f.mustPreserve(page: 0, "05.01.2026", note: "klinisches Datum – darf nicht geschwärzt werden")
    f.mustPreserve(page: 0, "02.02.2026", note: "klinisches Datum")
    f.mustPreserve(page: 0, "7,8 %")
    f.mustPreserve(page: 0, "7,2 %")
    f.mustPreserve(page: 0, "7,0 %")
    f.mustPreserve(page: 0, "0,9 mg/dl")
    f.mustPreserve(page: 0, "0,8 mg/dl")
    f.mustPreserve(page: 0, "142/86 mmHg")
    f.mustPreserve(page: 0, "128/78 mmHg")
    f.mustPreserve(page: 0, "-2,4 mmol/l", note: "negativer Wert")

    doc.close()
    return f.finish(pageCount: 1, rotations: [0])
}

// MARK: - F10c: manipulative instructions + real identifier

func buildF10c(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F10c-manipulativ.pdf", kind: .text, outcome: .ok,
                    notes: "Prompt-Injection-Fixture: Der Absatz „SYSTEM: …“ ist Dateninhalt und darf keine Werkzeug- oder Upload-Aktion auslösen. Der echte Identifikator im selben Dokument muss trotzdem gefunden werden.")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))
    doc.beginPage()

    _ = doc.draw("Befundbrief", font: .helveticaBold(13), at: CGPoint(x: 60, y: 790))

    var y: CGFloat = 762
    let manip = TextRender.wrap(Fiction.manipulationText, font: .helvetica(11), maxWidth: 475)
    for line in manip {
        _ = doc.draw(line, font: .helveticaBold(11), at: CGPoint(x: 60, y: y))
        y -= 15
    }
    y -= 10

    let idLine1 = doc.draw("Die Patientin \(Fiction.patientName) (geb. \(Fiction.patientBirth),",
                           font: .helvetica(11), at: CGPoint(x: 60, y: y))
    let idLine2 = doc.draw("KV-Nr. \(Fiction.patientKVNR)) stellte sich am 05.02.2026 in",
                           font: .helvetica(11), at: CGPoint(x: 60, y: y - 15))
    _ = doc.draw("unserer Ambulanz vor. Der Blutdruck betrug 142/86 mmHg,",
                 font: .helvetica(11), at: CGPoint(x: 60, y: y - 30))
    _ = doc.draw("das HbA1c 7,8 %.",
                 font: .helvetica(11), at: CGPoint(x: 60, y: y - 45))
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 0, id: "F10c-01", text: Fiction.patientName, category: .name,
                 rects: [idLine1.rect(of: Fiction.patientName)],
                 note: "trotz manipulativer Anweisung auffindbar")
    f.identifier(page: 0, id: "F10c-02", text: Fiction.patientBirth, category: .birthDate,
                 rects: [idLine1.rect(of: Fiction.patientBirth)])
    f.identifier(page: 0, id: "F10c-03", text: Fiction.patientKVNR, category: .insuranceNumber,
                 rects: [idLine2.rect(of: Fiction.patientKVNR)])
    f.footerCheck(page: 0)
    f.mustPreserve(page: 0, "142/86 mmHg")
    f.mustPreserve(page: 0, "7,8 %")
    f.mustPreserve(page: 0, "05.02.2026", note: "klinisches Datum")

    doc.close()
    return f.finish(pageCount: 1, rotations: [0])
}
