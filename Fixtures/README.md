# PaperVeil – Synthetischer Testsatz (Pflicht-Regressionssatz)

Dieses Verzeichnis enthält den maschinenlesbar annotierten, vollständig
**synthetischen** Regressionstestsatz für PaperVeil (siehe
`docs/ZIELZUSTAND.md`, Abschnitt 5 „Pflicht-Testsatz“, Kriterien B02, B05, B06,
C04, C05).

> **Alle Personen, Adressen, Telefonnummern, KV-Nummern, E-Mail-Adressen und
> Institutionen sind frei erfunden** („Mustermann“-Platzhalter). Es liegen
> keine echten Befunde oder Patientendaten vor. Jede PDF-Seite trägt den
> Fußzeilenvermerk *„SYNTHETISCHES TESTDOKUMENT – fiktive Daten“*.

Erzeugt wird der Satz deterministisch (feste Seeds, feste Inhalte-Daten) vom
Generator `pv-fixtures` (SwiftPM-Target, hängt nur an `PaperVeilCore`):

```bash
swift run pv-fixtures Fixtures/synthetic
```

Der Generator schreibt die PDFs und `annotations.json` und prüft sie danach
selbst (siehe unten). Schlägt eine Prüfung fehl, beendet er sich mit
Exit-Status ≠ 0. Die PDF-Metadaten (`/CreationDate`, `/ModDate`, `/ID`)
enthalten den Erzeugungszeitpunkt und variieren daher zwischen Läufen; **Inhalt,
Layout, Geometrie und `annotations.json` sind byte-identisch reproduzierbar.**

## Dokumente

| Datei | Art | Zweck | Erwartete Identifikatoren |
|---|---|---|---|
| `F01-arztbrief.pdf` | Text, 3 S. | Mehrseitiger Arztbrief; wiederholter Name (6×, über Seiten verteilt), Adresse, „geb.“-Geburtsdatum, KV-Nr., Telefon, E-Mail, Patienten-ID; Klinik-/Arztbriefkopf ist **nicht** annotiert (Absender ≠ Patient). | 12 |
| `F02-laborblatt.pdf` | Text, 1 S. | Laborblatt mit 7,5-pt-Courier-Tabelle, Dezimalkommas, negativem Wert (`Base Excess -2,4 mmol/l`), Einheiten, Referenzbereichen, Flaggen. | 2 |
| `F03-medikationsplan.pdf` | Text, 1 S. | Medikationsplan mit Dosierungen (`1-0-1`, `500 mg`, `0-0-1/2`), Startdaten und klinisch relevanten Verneinungen („Keine Penicillinallergie bekannt.“ / „Kein Marcumar.“). | 3 |
| `F04-scan.pdf` | Scan, 1 S. | Reiner Bildscan (150 dpi Graustufen, keine Textebene) mit sichtbaren Identifikatoren und QR-Code (CoreImage, fiktiver Inhalt). QR-Bereich ist `manualOnly`. | 4 + 1 manuell |
| `F05-rotation-beschnitt.pdf` | Text, 4 S. | `/Rotate 90` und `/Rotate 180`; CropBox kleiner als MediaBox, KV-Nr. **außerhalb der CropBox** im Content-Stream (hidden/outsideCropBox); Identifikatoren über Zeilenumbrüche (`Muster-`/`mann`; `X1234`/`56789`). | 10 |
| `F06-gemischt.pdf` | Gemischt, 3 S. | Textseiten 0 und 2, reine Scanseite (200 dpi) dazwischen. | 8 |
| `F07-versteckt.pdf` | Text, 1 S. | Versteckte Identifikatoren in fünf Nebenkanälen: unsichtbare Textebene (Render-Modus 3), weiß-auf-weiß, Dokument-Info (Title/Subject/Keywords), AcroForm-Textfeld, Text-Annotation, eingebetteter Dateianhang (`/Names /EmbeddedFiles`, als rohes PDF inkrementell angehängt). Keine sichtbaren Identifikatoren. | 12 (alle hidden) |
| `F08-schlechter-scan.pdf` | Scan, 1 S. | Absichtlich schlechter Scan (~100 dpi, Rauschen, Unschärfe, Schräglage): OCR unsicher; handschriftlich-artige KV-Nr. (`expectOCRUncertain`), Label und Wert weit auseinander (`expectedMappingProblem`). | 3 |
| `F09-ohne-identifikatoren.pdf` | Text, 1 S. | Fehlalarmkontrolle: nur klinische Zahlen und Daten, keine direkten Identifikatoren. Erwartet: **keine** Fundstellen. | 0 |
| `F10a-beschaedigt.pdf` | Ungültig | Bei ~50 % abgeschnittener Bytestream (kein `%%EOF`, kein xref). Erwartet: Eingabe als beschädigt erkannt; PDFKit kann sie nicht öffnen. | – |
| `F10b-verschluesselt.pdf` | Ungültig | Passwortverschlüsselt (Benutzerpasswort **`test`**, Eigentümerpasswort `fixture-owner`). | 2 (nach Entschlüsselung) |
| `F10c-manipulativ.pdf` | Text, 1 S. | Prompt-Injection-Fixture: eingebettete manipulative „SYSTEM:“-Anweisung ist Dateninhalt; der echte Identifikator im selben Dokument muss trotzdem gefunden werden. | 3 |

Alle Scans sind Graustufen (~150–200 dpi; F08 bewusst ~100 dpi). Das
Gesamtverzeichnis bleibt deutlich unter 10 MB.

## Schema von `annotations.json`

```jsonc
{
  "schemaVersion": 1,
  "generator": "pv-fixtures",
  "contentDate": "2026-02-05",        // logisches Fixturedatum
  "policy": {
    "statement": "…alles fiktiv…",
    "patientDataIsIdentifier": true,   // Patientendaten = zu schwärzen
    "clinicAndPhysicianDataIsIdentifier": false, // Entscheidung: Absender ist nicht der Betroffene
    "annotationSpace": "unrotated mediaBox page space, Punkt, Ursprung unten links (PageRect)",
    "footer": "SYNTHETISCHES TESTDOKUMENT – fiktive Daten"
  },
  "documents": [ /* pro Dokument: */ {
    "file": "F01-arztbrief.pdf",
    "kind": "text" | "scan" | "mixed" | "invalid",
    "expectedInputOutcome": "ok" | "damaged" | "encrypted",
    "password": null,                  // nur F10b: "test" (Benutzerpasswort)
    "pageCount": 3,                    // F10a: Seitenzahl des Originaldokuments
    "pageRotations": [0, 0, 0],        // /Rotate je Seite
    "notes": "…",
    "identifiers": [ /* je erwartetem Identifikator: */ {
      "id": "F01-01",
      "pageIndex": 0,
      "text": "Erika Mustermann",      // exakt wie im Seitentext; Zeilenumbrüche als \n
      "category": "name",              // IdentifierCategory-Raw-Wert aus PaperVeilCore
      "rects": [ { "x": 0, "y": 0, "width": 0, "height": 0 } ], // PageRect, exakt aus der Zeichnung
      "occurrence": 0,                 // 0-basierter Treffer des Texts im Seiteninhalt (Text-PDFs)
      "hidden": false,
      "channel": null,                 // invisibleText | metadata | form | annotation | attachment | outsideCropBox
      "manualOnly": false,             // true: ohne Textsemantik manuell zu schwärzen (QR)
      "expectOCRUncertain": false,     // true: OCR dieses Identifikators vermutlich falsch
      "expectedMappingProblem": false, // true: Label und Wert weit auseinander
      "note": null
    } ],
    "mustPreserve": [ /* je Seite zu erhaltender medizinischer Inhalt: */ {
      "pageIndex": 0,
      "text": "142/86 mmHg",           // muss außerhalb freigegebener Schwärzungen lesbar bleiben
      "rect": null,                    // nur bei Scan-Seiten (Pixelprüfung), sonst Textprüfung
      "note": "Blutdruckwert mit Schrägstrich"
    } ]
  } ]
}
```

Konventionen:

- **Rects** liegen im *unrotierten* MediaBox-Seitenraum (Punkt, Ursprung
  unten links), identisch zur `PageRect`-Konvention in `PaperVeilCore`. Bei
  Identifikatoren über Zeilenumbrüche enthält `rects` ein Rect je Zeile.
- **`occurrence`** ist der 0-basierte Index des Treffers unter allen
  (whitespace-normalisierten) Vorkommen von `text` im extrahierten Seitentext;
  jeder Identifikator im Seiteninhalt ist annotiert. `null` bei Scan-Seiten und
  Nebenkanälen ohne Seitenbezug (metadata, attachment).
- Optionale Felder (`occurrence`, `channel`, `note`, `password`) fehlen im JSON,
  wenn sie `null` sind.
- Kategorien sind die Raw-Werte von `IdentifierCategory`: `name`, `address`,
  `birthDate`, `phone`, `email`, `insuranceNumber`, `patientID`, `other`, `image`.
- **Entscheidung Klinik-/Arztdaten:** Klinikname, Klinikadresse, Arztname und
  Praxisstempel sind der *Absender* medizinischer Schreiben, nicht die zu
  schützende Person, und werden in diesem Testsatz bewusst **nicht** als
  Identifikatoren annotiert (`policy.clinicAndPhysicianDataIsIdentifier`).
  Auswertungen dürfen diese Entscheidung separat prüfen.

## Selbstprüfung des Generators

`swift run pv-fixtures` verifiziert nach dem Schreiben jedes Dokument gegen die
eigene Annotation (kein Swift-Testing nötig) und schlägt bei jedem Fehler mit
Exit-Status ≠ 0 fehl:

- **Text-PDFs**: Jeder erwartete Identifikator ist im `PDFPage.string`
  auffindbar (whitespace-normalisiert, „modulo Zeilenumbrüche“; mehrzeilige
  Identifikatoren teilenweise) und jedes annotierte Rect schneidet die
  PDFKit-Auswahlgeometrie (`PDFSelection.bounds(for:)`) des Treffers.
- **mustPreserve**: Text-PDFs per `page.string`, Scan-Seiten per gerenderten
  Pixeln im annotierten Rect (PDFKit-Thumbnail).
- **Scans**: Seite hat keine Textebene (`page.string` leer/nil);
  Identifikatoren- und QR-Bereiche enthalten beim Rendern dunkle Pixel.
- **F05**: `/Rotate` je Seite und CropBox via `CGPDFDocument`; der
  außerhalb der CropBox gezeichnete Identifikator steht nachweislich im
  (flate-dekomprimierten) Content-Stream und wird von der PDFKit-Extraktion
  **nicht** geliefert.
- **F07**: Dokument-Info-Metadaten, AcroForm-Feldwert, Text-Annotation und
  `/Names /EmbeddedFiles` im Katalog werden nach dem Schreiben wieder
  eingelesen und geprüft.
- **F10a**: Datei ist kleiner als das Original und öffnet nicht vollständig.
- **F10b**: Dokument ist verschlüsselt und lässt sich mit dem
  Benutzerpasswort `test` entschlüsseln.
- **Datenschutz**: Kein erzeugtes PDF enthält den echten macOS-Benutzernamen
  (PDFKit trägt ihn sonst automatisch in Annotationen ein; der Generator
  überschreibt ihn mit fiktiven Namen und prüft die Bytes).

## Bekannte Einschränkungen

- PDF-Metadaten-Zeitstempel und `/ID` variieren zwischen Läufen (s. o.); der
  fachliche Inhalt nicht.
- Die Rects von F08 sind die Layout-Koordinaten vor Degradierung; durch die
  leichte Schräglage weicht die tatsächliche Pixelposition um wenige Punkt ab
  (in der Annotation als `expectOCRUncertain`/`expectedMappingProblem`
  dokumentiert).
- `pageCount` von `F10a-beschaedigt.pdf` bezeichnet das unbeschädigte
  Originaldokument.
