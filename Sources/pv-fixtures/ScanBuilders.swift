import CoreGraphics
import Foundation
import PaperVeilCore

// MARK: - Scan page embedding

/// Embeds a rasterized page image as the sole content of a new PDF page
/// (a pure scan page: no text layer).
func embedScanPage(_ doc: PDFDoc, image: CGImage) {
    doc.beginPage()
    doc.ctx.draw(image, in: CGRect(origin: .zero, size: kA4))
    doc.endPage()
}

// MARK: - F04: pure image scan with QR code

func buildF04(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F04-scan.pdf", kind: .scan, outcome: .ok,
                    notes: "Reiner Bildscan (eine Rasterseite ohne Textebene, 150 dpi Graustufen) mit sichtbaren Identifikatoren und QR-Code. Der QR-Bereich ist als manualRegion annotiert (manuell zu schwärzen). Praxis-/Arztdaten sind nicht annotiert.")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))

    let page = RasterPage(size: kA4, dpi: 150)
    page.draw(Fiction.practiceName, font: .helveticaBold(12), at: CGPoint(x: 60, y: 790))
    page.draw("\(Fiction.practiceStreet) · \(Fiction.practiceCity)", font: .helvetica(9), at: CGPoint(x: 60, y: 774))
    page.draw("Tel. +49 30 9876543 · musterklinik@example.org", font: .helvetica(9), at: CGPoint(x: 60, y: 762))
    page.rule(from: CGPoint(x: 60, y: 752), to: CGPoint(x: 535, y: 752))

    page.draw("Überweisung", font: .helveticaBold(13), at: CGPoint(x: 60, y: 724))
    let nameL = page.draw("Patient:     \(Fiction.patient2Name)", font: .helvetica(11), at: CGPoint(x: 60, y: 696))
    let birthL = page.draw("geb.:        \(Fiction.patient2Birth)", font: .helvetica(11), at: CGPoint(x: 60, y: 680))
    let streetL = page.draw("Anschrift:   \(Fiction.patient2Street)", font: .helvetica(11), at: CGPoint(x: 60, y: 664))
    let cityL = page.draw("             \(Fiction.patient2City)", font: .helvetica(11), at: CGPoint(x: 60, y: 648))
    let kvL = page.draw("KV-Nr.:      \(Fiction.patient2KVNR)", font: .helvetica(11), at: CGPoint(x: 60, y: 632))
    let dateL = page.draw("Datum:       \(Fiction.letterDate)", font: .helvetica(11), at: CGPoint(x: 60, y: 616))
    page.rule(from: CGPoint(x: 60, y: 602), to: CGPoint(x: 535, y: 602))
    let verL = page.draw("Veranlassung: Verlaufskontrolle Diabetes mellitus Typ 2",
                         font: .helvetica(11), at: CGPoint(x: 60, y: 580))
    let befL = page.draw("Befund: HbA1c 7,8 %, Blutdruck 142/86 mmHg",
                         font: .helvetica(11), at: CGPoint(x: 60, y: 562))

    let qrRect = page.drawQR(content: Fiction.qrContent, at: CGPoint(x: 445, y: 470), size: 90)
    page.draw("Scancode Patientenausweis", font: .helvetica(8), at: CGPoint(x: 445, y: 368))

    let footerL = page.drawFooter(size: kA4)

    var image = page.image
    image = ScanEffects.addNoise(image, amount: 4, seed: 2026_02_05)

    embedScanPage(doc, image: image)
    doc.close()

    // Identifiers (visible in the raster; no text layer).
    f.scanIdentifier(page: 0, id: "F04-01", text: Fiction.patient2Name, category: .name,
                    rects: [nameL.rect(of: Fiction.patient2Name)])
    f.scanIdentifier(page: 0, id: "F04-02", text: Fiction.patient2Birth, category: .birthDate,
                    rects: [birthL.rect(of: Fiction.patient2Birth)])
    f.scanIdentifier(page: 0, id: "F04-03",
                     text: "\(Fiction.patient2Street)\n\(Fiction.patient2City)", category: .address,
                     rects: [streetL.rect, cityL.rect], note: "Adresse über zwei Zeilen")
    f.scanIdentifier(page: 0, id: "F04-04", text: Fiction.patient2KVNR, category: .insuranceNumber,
                    rects: [kvL.rect(of: Fiction.patient2KVNR)])
    f.manualRegion(page: 0, id: "F04-05", text: "QR-Code (Inhalt: \(Fiction.qrContent))",
                   category: .image, rect: qrRect,
                   note: "QR-Code-Bereich muss manuell geschwärzt werden (manualRegion).")
    f.noTextLayer(page: 0)
    f.footerCheckScan(page: 0, rect: footerL.rect)

    f.mustPreserveScan(page: 0, "\(Fiction.letterDate)", rect: dateL.rect(of: Fiction.letterDate),
                       note: "klinisches Datum (nicht Geburtsdatum)")
    f.mustPreserveScan(page: 0, "Verlaufskontrolle Diabetes mellitus Typ 2", rect: verL.rect(of: "Verlaufskontrolle"),
                       note: "Veranlassung")
    f.mustPreserveScan(page: 0, "HbA1c 7,8 %", rect: befL.rect(of: "HbA1c"), note: "Laborwert")
    f.mustPreserveScan(page: 0, "142/86 mmHg", rect: befL.rect(of: "142/86"), note: "Blutdruck")

    return f.finish(pageCount: 1, rotations: [0])
}

// MARK: - F06: mixed text and scan pages

func buildF06(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F06-gemischt.pdf", kind: .mixed, outcome: .ok,
                    notes: "Gemischtes PDF: Textseiten (0 und 2) und eine reine Scanseite (1, 200 dpi Graustufen).")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))

    // -------- Page 0: text --------
    doc.beginPage()
    _ = doc.draw("Arztbrief – Auszug", font: .helveticaBold(13), at: CGPoint(x: 60, y: 780))
    let n1 = doc.draw("Patientin: \(Fiction.patient3Name)", font: .helvetica(11), at: CGPoint(x: 60, y: 752))
    let n2 = doc.draw("geb.: \(Fiction.patient3Birth)     KV-Nr.: \(Fiction.patient3KVNR)",
                      font: .helvetica(11), at: CGPoint(x: 60, y: 736))
    let n3 = doc.draw("Anschrift: \(Fiction.patient3Street), \(Fiction.patient3City)",
                      font: .helvetica(11), at: CGPoint(x: 60, y: 720))
    _ = doc.drawParagraph("Die Patientin stellte sich am \(Fiction.letterDate) mit Schwindel vor. "
                         + "Der Blutdruck betrug 150/95 mmHg, der Puls 88/min. Der Blutzucker lag bei "
                         + "112 mg/dl. Base Excess -1,8 mmol/l.",
                         font: .helvetica(11), at: CGPoint(x: 60, y: 690), maxWidth: 475, leading: 15)
    doc.drawFooter()
    doc.endPage()

    // -------- Page 1: scan --------
    let scan = RasterPage(size: kA4, dpi: 200)
    scan.draw("Notfallaufnahme – Aufnahmedokument", font: .helveticaBold(12), at: CGPoint(x: 60, y: 790))
    let sName = scan.draw("Patient:   \(Fiction.patient2Name)", font: .helvetica(11), at: CGPoint(x: 60, y: 762))
    let sBirth = scan.draw("geb.:      \(Fiction.patient2Birth)", font: .helvetica(11), at: CGPoint(x: 60, y: 746))
    let sKV = scan.draw("KV-Nr.:    \(Fiction.patient2KVNR)", font: .helvetica(11), at: CGPoint(x: 60, y: 730))
    let sDate = scan.draw("Aufnahme: \(Fiction.letterDate), 22:15 Uhr", font: .helvetica(11), at: CGPoint(x: 60, y: 714))
    scan.rule(from: CGPoint(x: 60, y: 702), to: CGPoint(x: 535, y: 702))
    let sBef = scan.draw("Befund: Blutdruck 150/95 mmHg, Puls 88/min.", font: .helvetica(11), at: CGPoint(x: 60, y: 682))
    let sFooter = scan.drawFooter(size: kA4)
    var image = scan.image
    image = ScanEffects.addNoise(image, amount: 4, seed: 2026_02_06)
    embedScanPage(doc, image: image)

    // -------- Page 2: text --------
    doc.beginPage()
    _ = doc.draw("Fortsetzung", font: .helveticaBold(13), at: CGPoint(x: 60, y: 780))
    let n4 = doc.drawParagraph("Die Patientin \(Fiction.patient3Name) wurde über Nacht stabilisiert. "
                              + "Empfehlung: Kontrolle in drei Tagen. RR 132/84 mmHg, HbA1c 7,4 %.",
                              font: .helvetica(11), at: CGPoint(x: 60, y: 750), maxWidth: 475, leading: 15)
    doc.drawFooter()
    doc.endPage()
    doc.close()

    // Page 0 identifiers.
    f.identifier(page: 0, id: "F06-01", text: Fiction.patient3Name, category: .name,
                 rects: [n1.rect(of: Fiction.patient3Name)])
    f.identifier(page: 0, id: "F06-02", text: Fiction.patient3Birth, category: .birthDate,
                 rects: [n2.rect(of: Fiction.patient3Birth)])
    f.identifier(page: 0, id: "F06-03", text: Fiction.patient3KVNR, category: .insuranceNumber,
                 rects: [n2.rect(of: Fiction.patient3KVNR)])
    f.identifier(page: 0, id: "F06-04",
                 text: "\(Fiction.patient3Street), \(Fiction.patient3City)", category: .address,
                 rects: [n3.rect(of: "\(Fiction.patient3Street), \(Fiction.patient3City)")])
    f.footerCheck(page: 0)
    f.mustPreserve(page: 0, "150/95 mmHg", note: "Blutdruck")
    f.mustPreserve(page: 0, "112 mg/dl", note: "Blutzucker")
    f.mustPreserve(page: 0, "-1,8 mmol/l", note: "negativer Wert")
    f.mustPreserve(page: 0, Fiction.letterDate, note: "klinisches Datum")

    // Page 1 identifiers (scan).
    f.scanIdentifier(page: 1, id: "F06-05", text: Fiction.patient2Name, category: .name,
                     rects: [sName.rect(of: Fiction.patient2Name)])
    f.scanIdentifier(page: 1, id: "F06-06", text: Fiction.patient2Birth, category: .birthDate,
                     rects: [sBirth.rect(of: Fiction.patient2Birth)])
    f.scanIdentifier(page: 1, id: "F06-07", text: Fiction.patient2KVNR, category: .insuranceNumber,
                     rects: [sKV.rect(of: Fiction.patient2KVNR)])
    f.noTextLayer(page: 1)
    f.footerCheckScan(page: 1, rect: sFooter.rect)
    f.mustPreserveScan(page: 1, "\(Fiction.letterDate), 22:15 Uhr",
                       rect: sDate.rect(of: "22:15"), note: "klinisches Datum mit Uhrzeit")
    f.mustPreserveScan(page: 1, "Blutdruck 150/95 mmHg", rect: sBef.rect(of: "150/95"),
                       note: "Blutdruck")

    // Page 2 identifiers.
    let nameLine = n4.first { $0.drawn.text.contains(Fiction.patient3Name) } ?? n4[0]
    f.identifier(page: 2, id: "F06-08", text: Fiction.patient3Name, category: .name,
                 rects: [nameLine.rect(of: Fiction.patient3Name)])
    f.footerCheck(page: 2)
    f.mustPreserve(page: 2, "132/84 mmHg", note: "Blutdruck")
    f.mustPreserve(page: 2, "7,4 %", note: "HbA1c")

    return f.finish(pageCount: 3, rotations: [0, 0, 0])
}

// MARK: - F08: bad scan (low res, noise, blur, skew)

func buildF08(url: URL) throws -> (DocumentAnnotation, [VerifyItem]) {
    let f = Fixture(file: "F08-schlechter-scan.pdf", kind: .scan, outcome: .ok,
                    notes: "Absichtlich schlechter Scan (~100 dpi, Rauschen, Unschärfe, leichte Schräglage), damit OCR unsicher ist. KV-Nr. handschriftlich-artig (expectOCRUncertain). Label und Wert der Namenszeile liegen weit auseinander (expectedMappingProblem).")
    let doc = try PDFDoc(url: url, defaultMediaBox: CGRect(origin: .zero, size: kA4))

    let page = RasterPage(size: kA4, dpi: 150)
    page.draw("Konsultationsnotiz", font: .helveticaBold(12), at: CGPoint(x: 60, y: 790))
    let praxis = page.draw("Praxis Musterstadt, \(Fiction.letterDate)", font: .helvetica(9), at: CGPoint(x: 60, y: 772))
    page.rule(from: CGPoint(x: 60, y: 760), to: CGPoint(x: 535, y: 760))

    // Label far left, value far right on the same baseline (mapping problem).
    page.draw("Patient", font: .helvetica(10), at: CGPoint(x: 60, y: 736))
    let nameL = page.draw(Fiction.patientName, font: .helvetica(10), at: CGPoint(x: 390, y: 736))
    page.draw("geb.", font: .helvetica(10), at: CGPoint(x: 60, y: 716))
    let birthL = page.draw(Fiction.patientBirth, font: .helvetica(10), at: CGPoint(x: 390, y: 716))
    page.draw("Diagnose", font: .helvetica(10), at: CGPoint(x: 60, y: 696))
    let diagL = page.draw("Diabetes mellitus Typ 2", font: .helvetica(10), at: CGPoint(x: 390, y: 696))
    page.rule(from: CGPoint(x: 60, y: 680), to: CGPoint(x: 535, y: 680))

    let befL = page.draw("Befund: RR 142/86 mmHg, HbA1c 7,8 %.", font: .helvetica(10), at: CGPoint(x: 60, y: 658))
    let therL = page.draw("Therapie: Metformin 500 mg 1-0-1.", font: .helvetica(10), at: CGPoint(x: 60, y: 640))

    // Handwriting-ish KV number (OCR expected to be wrong).
    page.draw("KV-Nr. (handschriftlich):", font: .helvetica(10), at: CGPoint(x: 60, y: 320))
    let kvL = page.draw(Fiction.patientKVNR, font: .zapfino(15), at: CGPoint(x: 190, y: 318))

    let footerL = page.drawFooter(size: kA4)

    var image = page.image
    image = ScanEffects.downscale(image, by: 1.5)     // ~100 dpi
    image = ScanEffects.boxBlur(image, radius: 1)
    image = ScanEffects.addNoise(image, amount: 20, seed: 2026_02_08)
    image = ScanEffects.skew(image, degrees: 0.9, canvas: CGSize(width: image.width, height: image.height))

    embedScanPage(doc, image: image)
    doc.close()

    f.scanIdentifier(page: 0, id: "F08-01", text: Fiction.patientName, category: .name,
                     rects: [nameL.rect(of: Fiction.patientName)],
                     mappingProblem: true, pixelThreshold: 225,
                     note: "Label „Patient“ links, Wert weit rechts – Zuordnung Label↔Wert ist ein erkennbares Mapping-Problem.")
    f.scanIdentifier(page: 0, id: "F08-02", text: Fiction.patientBirth, category: .birthDate,
                     rects: [birthL.rect(of: Fiction.patientBirth)], pixelThreshold: 225)
    f.scanIdentifier(page: 0, id: "F08-03", text: Fiction.patientKVNR, category: .insuranceNumber,
                     rects: [kvL.rect],
                     ocrUncertain: true, pixelThreshold: 225,
                     note: "Handschriftlich-artig (Zapfino) auf schlechtem Scan – OCR wird mit hoher Wahrscheinlichkeit falsch.")
    f.noTextLayer(page: 0)
    f.footerCheckScan(page: 0, rect: footerL.rect, threshold: 225)

    f.mustPreserveScan(page: 0, "RR 142/86 mmHg", rect: befL.rect(of: "142/86"), pixelThreshold: 225, note: "Blutdruck")
    f.mustPreserveScan(page: 0, "HbA1c 7,8 %", rect: befL.rect(of: "7,8"), pixelThreshold: 225, note: "Laborwert")
    f.mustPreserveScan(page: 0, "Metformin 500 mg 1-0-1", rect: therL.rect(of: "Metformin"),
                       pixelThreshold: 225, note: "Dosierung und Schema")
    f.mustPreserveScan(page: 0, "Diabetes mellitus Typ 2", rect: diagL.rect(of: "Diabetes"),
                       pixelThreshold: 225, note: "Diagnose")
    f.mustPreserveScan(page: 0, "\(Fiction.letterDate)", rect: praxis.rect(of: Fiction.letterDate),
                       pixelThreshold: 225, note: "klinisches Datum")

    return f.finish(pageCount: 1, rotations: [0])
}
