import Foundation
import PDFKit
import AppKit
import PaperVeilCore

// MARK: - F05: rotated, cropped, line-broken identifiers

func buildF05(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F05-rotation-beschnitt.pdf", kind: .text, outcome: .ok,
                    notes: "Seite 0: /Rotate 90. Seite 1: /Rotate 180. Seite 2: CropBox kleiner als MediaBox; die KV-Nr. steht senkrecht im Randstreifen AUSSERHALB der CropBox (hidden/outsideCropBox), bleibt aber im Content-Stream. Seite 3: Identifikatoren über Zeilenumbrüche („Muster-“/„mann“; KV-Nr. „X1234“/„56789“). Alle Rects im ungedrehten MediaBox-Seitenraum.")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))

    // -------- Page 0: will get /Rotate 90 --------
    doc.beginPage()
    _ = doc.draw("Verlaufsdokumentation", font: .helveticaBold(13), at: CGPoint(x: 60, y: 770))
    let r0name = doc.draw("Patientin: \(Fiction.patientName)", font: .helvetica(11), at: CGPoint(x: 60, y: 742))
    let r0birth = doc.draw("geb.: \(Fiction.patientBirth)", font: .helvetica(11), at: CGPoint(x: 60, y: 726))
    let r0kv = doc.draw("KV-Nr.: \(Fiction.patientKVNR)", font: .helvetica(11), at: CGPoint(x: 60, y: 710))
    _ = doc.draw("Blutzucker nüchtern: 132 mg/dl. RR 138/82 mmHg.", font: .helvetica(11), at: CGPoint(x: 60, y: 684))
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 0, id: "F05-01", text: Fiction.patientName, category: .name,
                 rects: [r0name.rect(of: Fiction.patientName)], note: "Seite mit /Rotate 90")
    f.identifier(page: 0, id: "F05-02", text: Fiction.patientBirth, category: .birthDate,
                 rects: [r0birth.rect(of: Fiction.patientBirth)])
    f.identifier(page: 0, id: "F05-03", text: Fiction.patientKVNR, category: .insuranceNumber,
                 rects: [r0kv.rect(of: Fiction.patientKVNR)])
    f.footerCheck(page: 0)
    f.mustPreserve(page: 0, "132 mg/dl", note: "Blutzucker")
    f.mustPreserve(page: 0, "138/82 mmHg", note: "Blutdruck")

    // -------- Page 1: will get /Rotate 180 --------
    doc.beginPage()
    _ = doc.draw("Zweiter Befund", font: .helveticaBold(13), at: CGPoint(x: 60, y: 770))
    let r1name = doc.draw("Frau Mustermann stellte sich zur Kontrolle vor.",
                          font: .helvetica(11), at: CGPoint(x: 60, y: 742))
    let r1tel = doc.draw("Erreichbar unter \(Fiction.patientPhone).", font: .helvetica(11), at: CGPoint(x: 60, y: 726))
    _ = doc.draw("HbA1c 7,2 %. Keine Hypoglykämie aufgetreten.", font: .helvetica(11), at: CGPoint(x: 60, y: 710))
    doc.drawFooter()
    doc.endPage()

    f.identifier(page: 1, id: "F05-04", text: "Frau Mustermann", category: .name,
                 rects: [r1name.rect(of: "Frau Mustermann")], note: "Seite mit /Rotate 180")
    f.identifier(page: 1, id: "F05-05", text: Fiction.patientPhone, category: .phone,
                 rects: [r1tel.rect(of: Fiction.patientPhone)])
    f.footerCheck(page: 1)
    f.mustPreserve(page: 1, "7,2 %", note: "HbA1c")
    f.mustPreserve(page: 1, "Keine Hypoglykämie", note: "klinisch relevante Verneinung")

    // -------- Page 2: crop box + identifier outside the crop box --------
    // CropBox (80, 40, 435, 762): the left strip (x < 80) and the bottom strip
    // (y < 40) stay in the media box but are cut off in the cropped display.
    let crop = CGRect(x: 80, y: 40, width: 435, height: 762)
    doc.beginPage(crop: crop)
    _ = doc.draw("Konsiliarbefund", font: .helveticaBold(13), at: CGPoint(x: 100, y: 770))
    let r2name = doc.draw("Patientin: \(Fiction.patientName)", font: .helvetica(11), at: CGPoint(x: 100, y: 742))
    let r2street = doc.draw(Fiction.patientStreet, font: .helvetica(11), at: CGPoint(x: 100, y: 726))
    let r2city = doc.draw(Fiction.patientCity, font: .helvetica(11), at: CGPoint(x: 100, y: 710))
    // KV-Nr. in the left margin strip (x < 80) — outside the crop box. It stays
    // in the content stream and must be treated as a hidden identifier.
    let r2kv = doc.draw(Fiction.patientKVNR, font: .helvetica(7), at: CGPoint(x: 10, y: 420))
    _ = doc.draw("Kreatinin 0,9 mg/dl, Base Excess -2,4 mmol/l.",
                 font: .helvetica(11), at: CGPoint(x: 100, y: 684))
    _ = doc.drawFooter(atY: 48) // crop box starts at y = 40
    doc.endPage()

    f.identifier(page: 2, id: "F05-06", text: Fiction.patientName, category: .name,
                 rects: [r2name.rect(of: Fiction.patientName)], note: "innerhalb der CropBox")
    f.identifier(page: 2, id: "F05-07",
                 text: "\(Fiction.patientStreet)\n\(Fiction.patientCity)", category: .address,
                 rects: [r2street.rect, r2city.rect], note: "innerhalb der CropBox, zwei Zeilen")
    f.identifier(page: 2, id: "F05-08", text: Fiction.patientKVNR, category: .insuranceNumber,
                 rects: [r2kv.rect], hidden: true, channel: .outsideCropBox,
                 expectExtractable: false,
                 note: "Im linken Randstreifen außerhalb der CropBox gezeichnet; bleibt im Content-Stream, wird von der PDFKit-Textextraktion aber NICHT geliefert und muss als versteckter Identifikator behandelt werden.")
    f.checks.append(.absentFromPageText(page: 2, needle: Fiction.patientKVNR))
    f.footerCheck(page: 2)
    f.mustPreserve(page: 2, "0,9 mg/dl", note: "Kreatinin")
    f.mustPreserve(page: 2, "-2,4 mmol/l", note: "negativer Base Excess")

    // -------- Page 3: identifiers broken across line breaks --------
    doc.beginPage()
    _ = doc.draw("Ergänzung zum Befund", font: .helveticaBold(13), at: CGPoint(x: 60, y: 770))
    let lb1 = doc.draw("Bei Frau Erika Muster-", font: .helvetica(11), at: CGPoint(x: 60, y: 742))
    let lb2 = doc.draw("mann wurde die Dosis von Metformin auf", font: .helvetica(11), at: CGPoint(x: 60, y: 727))
    _ = doc.draw("2-mal 500 mg täglich erhöht.", font: .helvetica(11), at: CGPoint(x: 60, y: 712))
    let lb3 = doc.draw("Bitte bestätigen Sie die KV-Nr. X1234", font: .helvetica(11), at: CGPoint(x: 60, y: 682))
    let lb4 = doc.draw("56789 (Krankenkasse Beispielhafen).", font: .helvetica(11), at: CGPoint(x: 60, y: 667))
    _ = doc.draw("Rückfragen unter \(Fiction.patientPhone).", font: .helvetica(11), at: CGPoint(x: 60, y: 637))
    doc.drawFooter()
    doc.endPage()
    doc.close()

    f.identifier(page: 3, id: "F05-09", text: "Erika Muster-\nmann", category: .name,
                 rects: [lb1.rect(of: "Erika Muster-"), lb2.rect(of: "mann")],
                 note: "Name über Zeilenumbruch verteilt (Trennung mit Bindestrich).")
    f.identifier(page: 3, id: "F05-10", text: "X1234\n56789", category: .insuranceNumber,
                 rects: [lb3.rect(of: "X1234"), lb4.rect(of: "56789")],
                 note: "KV-Nr. über Zeilenumbruch verteilt (zwei Rects).")
    f.footerCheck(page: 3)
    f.mustPreserve(page: 3, "500 mg", note: "Dosierung")

    // -------- Post-process: /Rotate 90 (page 0) and /Rotate 180 (page 1) --------
    let data = try Data(contentsOf: url)
    guard let raw = RawPDF.parse(data) else {
        throw FixtureError.writeFailed("F05: PDF nicht parsebar für /Rotate-Update.")
    }
    let pages = raw.pageObjectNumbers()
    guard pages.count == 4 else {
        throw FixtureError.writeFailed("F05: erwartet 4 Seitenobjekte, gefunden \(pages.count).")
    }
    var updated: [(number: Int, body: Data)] = []
    if let b1 = RawPDFWriter.updatePageRotation(in: raw.body(of: pages[0]), degrees: 90) {
        updated.append((pages[0], b1))
    }
    if let b2 = RawPDFWriter.updatePageRotation(in: raw.body(of: pages[1]), degrees: 180) {
        updated.append((pages[1], b2))
    }
    guard updated.count == 2 else {
        throw FixtureError.writeFailed("F05: /Rotate-Eintrag konnte nicht eingefügt werden.")
    }
    try RawPDFWriter.appendIncrementalUpdate(to: url, updated: updated, added: [])

    f.checks.append(.rotations([90, 180, 0, 0]))
    f.checks.append(.cropBox(page: 2, rect: crop))
    // The outside-crop identifier is in the content stream (flate-inflated
    // check) but must NOT appear in the PDFKit extraction.
    f.checks.append(.contentStream(page: 2, needle: Fiction.patientKVNR))

    return f.finish(pageCount: 4, rotations: [90, 180, 0, 0])
}

// MARK: - F07: hidden identifiers in five side channels

func buildF07(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F07-versteckt.pdf", kind: .text, outcome: .ok,
                    notes: "Versteckte Identifikatoren in fünf Nebenkanälen: unsichtbare Textebene (Render-Modus 3), Weiß-auf-Weiß, Dokument-Info (Title/Subject/Keywords), AcroForm-Textfeld, Text-Annotation und eingebetteter Dateianhang (/Names /EmbeddedFiles, als rohes PDF angehängt). Keine sichtbaren Identifikatoren im Seiteninhalt.")
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("F07-stufe1.pdf")

    // -------- Stage 1: CoreGraphics (content + invisible text + metadata) --------
    let doc = try PDFDoc(url: tempURL, defaultMediaBox: CGRect(origin: .zero, size: kA4),
                         metadata: [
                            kCGPDFContextTitle: "Arztbrief \(Fiction.patientName) vom \(Fiction.letterDate)",
                            kCGPDFContextSubject: "Patientin \(Fiction.patientName), KV-Nr. \(Fiction.patientKVNR)",
                            kCGPDFContextKeywords: "\(Fiction.patientName), \(Fiction.patientKVNR), Diabetes",
                         ])
    doc.beginPage()
    _ = doc.draw(Fiction.clinicName, font: .helveticaBold(12), at: CGPoint(x: 60, y: 800))
    _ = doc.draw("Laborergebnis – Zwischenbericht", font: .helveticaBold(13), at: CGPoint(x: 60, y: 774))
    _ = doc.drawParagraph("Verlaufskontrolle Diabetes mellitus Typ 2: HbA1c 7,2 %, Nüchternblutdruck "
                         + "128/78 mmHg. Die Medikation wird fortgeführt. Kreatinin 0,9 mg/dl, "
                         + "Base Excess -1,8 mmol/l. Eine Kontrolle ist in vier Wochen geplant.",
                         font: .helvetica(11), at: CGPoint(x: 60, y: 740), maxWidth: 475, leading: 15)

    // Invisible text (Tr 3) and white-on-white in blank areas of the page.
    let invis1 = doc.drawInvisible(Fiction.patientName, font: .helvetica(11), at: CGPoint(x: 60, y: 500))
    let invis2 = doc.drawWhiteOnWhite(Fiction.patientKVNR, font: .helvetica(11), at: CGPoint(x: 60, y: 470))
    doc.drawFooter()
    doc.endPage()
    doc.close()

    // -------- Stage 2: PDFKit adds widget + text annotation --------
    guard let pdfKitDoc = PDFDocument(url: tempURL), let page = pdfKitDoc.page(at: 0) else {
        throw FixtureError.writeFailed("F07: Zwischen-PDF nicht durch PDFKit lesbar.")
    }
    // AcroForm text field (hidden) with the patient name as value.
    let widget = PDFAnnotation(bounds: NSRect(x: 60, y: 560, width: 200, height: 18),
                               forType: .widget, withProperties: nil)
    widget.widgetFieldType = .text
    widget.setValue("patientenname", forAnnotationKey: .textLabel)
    widget.userName = "patientenname"
    widget.setValue(Fiction.patientName, forAnnotationKey: .widgetValue)
    widget.setValue(2, forAnnotationKey: .flags)  // /F bit 2: hidden
    page.addAnnotation(widget)
    // Sticky note with an insurance number in its contents.
    // PDFKit would otherwise fill the annotation author with the *real*
    // macOS user name — override with a fictional one.
    let note = PDFAnnotation(bounds: NSRect(x: 500, y: 640, width: 20, height: 20),
                             forType: .text, withProperties: nil)
    note.contents = "KV-Nr. \(Fiction.patientKVNR) telefonisch bestätigt am \(Fiction.letterDate)."
    note.userName = "Beispielprüfer (SYNTHETISCH)"
    note.color = NSColor.systemYellow
    page.addAnnotation(note)
    let temp2URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("F07-stufe2.pdf")
    guard pdfKitDoc.write(to: temp2URL) else {
        throw FixtureError.writeFailed("F07: PDFKit-Schreiben fehlgeschlagen.")
    }
    try? FileManager.default.removeItem(at: tempURL)
    try FileManager.default.moveItem(at: temp2URL, to: url)

    // -------- Stage 3: raw incremental update adds /Names /EmbeddedFiles --------
    let fileContent = Fiction.attachmentContent
    let fileBody = Data("""
        << /Type /EmbeddedFile /Length \(fileContent.utf8.count) >>
        stream
        \(fileContent)
        endstream
        """.utf8)
    guard let raw = RawPDF.parse(try Data(contentsOf: url)) else {
        throw FixtureError.writeFailed("F07: PDFKit-Ausgabe nicht parsebar.")
    }
    // The writer allocates sequential numbers starting here:
    let filespecNumber = max(raw.trailerSize, (raw.objects.keys.max() ?? 0) + 1)
    let embeddedFileNumber = filespecNumber + 1
    let filespec = Data("""
        << /Type /Filespec /F (\(Fiction.attachmentName)) /EF << /F \(embeddedFileNumber) 0 R >> >>
        """.utf8)
    let catalogBody = raw.body(of: raw.rootNumber)
    guard catalogBody.range(of: "/Names") == nil else {
        throw FixtureError.writeFailed("F07: Katalog enthält bereits /Names.")
    }
    let newCatalog = RawPDF.inserting(
        "/Names << /EmbeddedFiles << /Names [ (\(Fiction.attachmentName)) \(filespecNumber) 0 R ] >> >>",
        atDictStartOf: catalogBody)
    try RawPDFWriter.appendIncrementalUpdate(
        to: url,
        updated: [(number: raw.rootNumber, body: Data(newCatalog.utf8))],
        added: [filespec, fileBody])

    // -------- annotations --------
    f.identifier(page: 0, id: "F07-01", text: Fiction.patientName, category: .name,
                 rects: [invis1.rect], hidden: true, channel: .invisibleText,
                 note: "Textebene mit Render-Modus 3 (unsichtbar).")
    f.identifier(page: 0, id: "F07-02", text: Fiction.patientKVNR, category: .insuranceNumber,
                 rects: [invis2.rect], hidden: true, channel: .invisibleText,
                 note: "Weiß auf weiß.")
    f.channelIdentifier(page: 0, id: "F07-03", text: Fiction.patientName, category: .name,
                        channel: .metadata,
                        note: "Title/Subject/Keywords des Dokument-Info-Dicts: „Arztbrief Erika Mustermann …“, „Patientin Erika Mustermann, KV-Nr. X123456789“.")
    f.channelIdentifier(page: 0, id: "F07-04", text: Fiction.patientKVNR, category: .insuranceNumber,
                        channel: .metadata,
                        note: "Subject/Keywords: „KV-Nr. X123456789“ bzw. „X123456789“.")
    f.channelIdentifier(page: 0, id: "F07-05", text: Fiction.patientName, category: .name,
                        channel: .form, rects: [CGRect(x: 60, y: 560, width: 200, height: 18)],
                        note: "AcroForm-Textfeld (versteckt, /F bit 2), /V = Erika Mustermann.")
    f.channelIdentifier(page: 0, id: "F07-06", text: Fiction.patientKVNR, category: .insuranceNumber,
                        channel: .annotation, rects: [CGRect(x: 500, y: 640, width: 20, height: 20)],
                        note: "Text-Annotation (Notiz) mit Inhalt „KV-Nr. X123456789 …“.")
    f.channelIdentifier(page: 0, id: "F07-07", text: Fiction.patientName, category: .name,
                        channel: .attachment, note: Fiction.attachmentName)
    f.channelIdentifier(page: 0, id: "F07-08", text: Fiction.patientBirth, category: .birthDate,
                        channel: .attachment, note: Fiction.attachmentName)
    f.channelIdentifier(page: 0, id: "F07-09", text: "\(Fiction.patientStreet), \(Fiction.patientCity)",
                        category: .address, channel: .attachment,
                        note: Fiction.attachmentName)
    f.channelIdentifier(page: 0, id: "F07-10", text: Fiction.patientKVNR, category: .insuranceNumber,
                        channel: .attachment, note: Fiction.attachmentName)
    f.channelIdentifier(page: 0, id: "F07-11", text: Fiction.patientPhone, category: .phone,
                        channel: .attachment, note: Fiction.attachmentName)
    f.channelIdentifier(page: 0, id: "F07-12", text: Fiction.patientEmail, category: .email,
                        channel: .attachment, note: Fiction.attachmentName)

    f.footerCheck(page: 0)
    f.mustPreserve(page: 0, "7,2 %", note: "HbA1c")
    f.mustPreserve(page: 0, "128/78 mmHg", note: "Blutdruck")
    f.mustPreserve(page: 0, "0,9 mg/dl", note: "Kreatinin")
    f.mustPreserve(page: 0, "-1,8 mmol/l", note: "negativer Base Excess")
    f.mustPreserve(page: 0, "Kontrolle ist in vier Wochen geplant", note: "klinische Empfehlung")

    // -------- checks --------
    f.checks.append(.pageText(page: 0, needle: Fiction.footer, occurrence: 0, rects: [], note: "footer"))
    f.checks.append(.pageText(page: 0, needle: Fiction.patientName, occurrence: 0,
                              rects: [invis1.rect], note: "unsichtbarer Text (Tr 3)"))
    f.checks.append(.pageText(page: 0, needle: Fiction.patientKVNR, occurrence: 0,
                              rects: [invis2.rect], note: "weiß auf weiß"))
    f.checks.append(.metadata(key: PDFDocumentAttribute.titleAttribute.rawValue, contains: Fiction.patientName))
    f.checks.append(.metadata(key: PDFDocumentAttribute.subjectAttribute.rawValue, contains: Fiction.patientKVNR))
    f.checks.append(.metadata(key: PDFDocumentAttribute.keywordsAttribute.rawValue, contains: Fiction.patientName))
    f.checks.append(.formField(page: 0, contains: Fiction.patientName))
    f.checks.append(.stickyNote(page: 0, contains: Fiction.patientKVNR))
    f.checks.append(.attachment(file: Fiction.attachmentName, contentContains: Fiction.patientKVNR))
    f.checks.append(.pageCount(1))

    return f.finish(pageCount: 1, rotations: [0])
}

// MARK: - F10a: damaged (truncated)

func buildF10a(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F10a-beschaedigt.pdf", kind: .invalid, outcome: .damaged,
                    notes: "Absichtlich beschädigt: Der bytestream wurde bei ca. 50 % abgeschnitten (kein %%EOF, kein vollständiges xref). pageCount bezeichnet das Originaldokument (2 Seiten). Erwartetes Verhalten: Eingabe wird als beschädigt erkannt, nicht als erfolgreich verarbeitet markiert; PDFKit kann die Datei nicht öffnen.")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))
    for page in 0..<2 {
        doc.beginPage()
        if page == 0 {
            _ = doc.draw("Reha-Bericht", font: .helveticaBold(13), at: CGPoint(x: 60, y: 770))
            _ = doc.draw("Patientin: \(Fiction.patientName)", font: .helvetica(11), at: CGPoint(x: 60, y: 742))
            _ = doc.draw("geb.: \(Fiction.patientBirth)", font: .helvetica(11), at: CGPoint(x: 60, y: 726))
            _ = doc.drawParagraph("Die Patientin befindet sich in stationärer Rehabilitation nach einer "
                                 + "ungeraden Verlaufssituation. HbA1c 7,2 %, RR 128/78 mmHg.",
                                 font: .helvetica(11), at: CGPoint(x: 60, y: 700), maxWidth: 475, leading: 15)
        } else {
            _ = doc.draw("Zusammenfassung", font: .helveticaBold(13), at: CGPoint(x: 60, y: 770))
            _ = doc.draw("Fortsetzung des Berichts mit Empfehlungen für die Anschlussbehandlung.",
                         font: .helvetica(11), at: CGPoint(x: 60, y: 742))
        }
        doc.drawFooter()
        doc.endPage()
    }
    doc.close()

    let originalBytes = try Data(contentsOf: url).count
    let result = try RawPDFWriter.truncate(url, fraction: 0.5)
    assert(result.originalBytes == originalBytes)

    f.checks.append(.damaged(originalPageCount: 2, originalBytes: originalBytes))
    return f.finish(pageCount: 2, rotations: [0, 0])
}

// MARK: - F10b: password-encrypted

func buildF10b(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F10b-verschluesselt.pdf", kind: .invalid, outcome: .encrypted,
                    password: Fiction.encryptionUserPassword,
                    notes: "Passwortverschlüsseltes PDF (Benutzerpasswort „test“, Eigentümerpasswort „fixture-owner“, via PDFKit geschrieben). Erwartetes Verhalten: als verschlüsselt erkannt, Entschlüsselung nur mit Passwort.")
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("F10b-plain.pdf")
    let doc = try PDFDoc(url: tempURL, defaultMediaBox: CGRect(origin: .zero, size: kA4))
    doc.beginPage()
    _ = doc.draw("Entlassungsbrief", font: .helveticaBold(13), at: CGPoint(x: 60, y: 780))
    let n1 = doc.draw("Patientin: \(Fiction.patientName)", font: .helvetica(11), at: CGPoint(x: 60, y: 752))
    let n2 = doc.draw("KV-Nr.: \(Fiction.patientKVNR)", font: .helvetica(11), at: CGPoint(x: 60, y: 736))
    _ = doc.drawParagraph("Entlassen am \(Fiction.letterDate). HbA1c bei Entlassung 7,2 %, "
                         + "RR 128/78 mmHg. Keine Hypoglykämie.",
                         font: .helvetica(11), at: CGPoint(x: 60, y: 706), maxWidth: 475, leading: 15)
    doc.drawFooter()
    doc.endPage()
    doc.close()

    // Encrypt with PDFKit (user password "test").
    guard let kitDoc = PDFDocument(url: tempURL) else {
        throw FixtureError.writeFailed("F10b: PDF nicht durch PDFKit lesbar.")
    }
    let options: [PDFDocumentWriteOption: Any] = [
        PDFDocumentWriteOption.userPasswordOption: Fiction.encryptionUserPassword,
        PDFDocumentWriteOption.ownerPasswordOption: Fiction.encryptionOwnerPassword,
    ]
    guard kitDoc.write(to: url, withOptions: options) else {
        throw FixtureError.writeFailed("F10b: verschlüsseltes Schreiben fehlgeschlagen.")
    }
    try? FileManager.default.removeItem(at: tempURL)

    f.identifier(page: 0, id: "F10b-01", text: Fiction.patientName, category: .name,
                 rects: [n1.rect(of: Fiction.patientName)], note: "nach Entschlüsselung auffindbar")
    f.identifier(page: 0, id: "F10b-02", text: Fiction.patientKVNR, category: .insuranceNumber,
                 rects: [n2.rect(of: Fiction.patientKVNR)])
    f.footerCheck(page: 0)
    f.checks.insert(.unlock(password: Fiction.encryptionUserPassword), at: 0)
    f.checks.append(.pageCount(1))
    f.mustPreserve(page: 0, "7,2 %", note: "HbA1c")
    f.mustPreserve(page: 0, "128/78 mmHg", note: "Blutdruck")
    f.mustPreserve(page: 0, "Keine Hypoglykämie", note: "Verneinung")
    f.mustPreserve(page: 0, Fiction.letterDate, note: "klinisches Datum")

    return f.finish(pageCount: 1, rotations: [0])
}
