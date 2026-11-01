# PaperVeil – Export-Audit (`pv-eval export-audit`)

- **Datum:** 2026-11-01T17:25:41Z
- **Git-Commit:** `8cbaf8783dba9c2a8c0134ad352be329a96edadf`
- **Betriebssystem:** macOS Version 27.2 (Build 26B123)
- **Werkzeugkette:** Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
- **Testsatz:** Fixtures/synthetic – Schema-Version 1
- **Arbeitsverzeichnis:** /var/folders/rt/f7w03_vd4b52gwc_kr2fdff40000gr/T/pv-eval-export-audit-7D3479D9
- **Raster-Auflösung:** 300 dpi

> Ergebnisse gelten nur für diesen synthetischen Testsatz und sind keine allgemeine Zusicherung.

## Gesamtergebnis

**BESTANDEN**

| Dokument | Ergebnis | Einschränkungen |
|---|---|---|
| `F01-arztbrief.pdf` | ✓ bestanden | – |
| `F02-laborblatt.pdf` | ✓ bestanden | 8 |
| `F03-medikationsplan.pdf` | ✓ bestanden | 4 |
| `F04-scan.pdf` | ✓ bestanden | – |
| `F05-rotation-beschnitt.pdf` | ✓ bestanden | – |
| `F06-gemischt.pdf` | ✓ bestanden | – |
| `F07-versteckt.pdf` | ✓ bestanden | – |
| `F08-schlechter-scan.pdf` | ✓ bestanden | – |
| `F09-ohne-identifikatoren.pdf` | ✓ bestanden | – |
| `F10c-manipulativ.pdf` | ✓ bestanden | – |

Negative Kontrolle (F01, schwarze Überlagerung): **wie erwartet FEHLGESCHLAGEN** – 12/12 Identifikatoren nach Textextraktion wiederherstellbar (C03-Prüfung schlägt fehl wie erwartet)

## `F01-arztbrief.pdf`

- Exportdatei: `PV-2BA1D831-r1.pdf` (SHA-256 `74d580873820bd0d…`)
- Original: 35663 B → Export: 746626 B (300 dpi, 3 Seiten)
- Schwärzungen: automatisch übernommen: 21, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000, S.2 0.000, S.3 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 2: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 3: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-2BA1D831-r1.pdf« enthält nichts vom Originalnamen »F01-arztbrief.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 12 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 3 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841, S.2 595x841, S.3 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 12 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 14 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »142/86 mmHg« | ✓ | ✓ | Blutdruckwert mit Schrägstrich |
| »7,8 %« | ✓ | ✓ | Dezimalkomma |
| »0,9 mg/dl« | ✓ | ✓ | Dezimalkomma + Einheit |
| »139 mmol/l« | ✓ | ✓ | Einheit |
| »-2,4 mmol/l« | ✓ | ✓ | negativer Wert |
| »20.01.2026 bis« | ✓ | ✓ | klinisches Datum (Aufnahme) |
| »02.02.2026« | ✓ | ✓ | klinisches Datum (Entlassung) |
| »27.01.2026« | ✓ | ✓ | klinisches Datum |
| »500 mg« | ✓ | ✓ | Dosierung |
| »128/78 mmHg« | ✓ | ✓ | Blutdruck |
| »01.02.2026« | ✓ | ✓ | klinisches Datum |
| »7,2 %« | ✓ | ✓ | Dezimalkomma |
| »Kontrolle in vier Wochen« | ✓ | ✓ | klinische Zeitangabe |
| »Blutzucker, HbA1c, Nierenwerte« | ✓ | ✓ | Kontrollparameter |

## `F02-laborblatt.pdf`

- Exportdatei: `PV-0C063630-r1.pdf` (SHA-256 `6e8dc048eb95c33b…`)
- Original: 45193 B → Export: 257570 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 5, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-0C063630-r1.pdf« enthält nichts vom Originalnamen »F02-laborblatt.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 2 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 2 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 14 geprüft; davon 8 auch im Original nicht lesbar, 1 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »13,8 g/dl« | ✓ (OCR-Toleranz*) | ✗ | Wert + Einheit (7,5 pt) |
| »41,2 %« | ✓ | ✓ |  |
| »9,6 /nl« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »248 /nl« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »139 mmol/l« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »3,4 mmol/l 3,5–5,1« | – (auch im Original nicht OCR-lesbar) | ✗ | erniedrigter Wert mit Flagge |
| »0,9 mg/dl« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »38 mg/dl« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »Base Excess -2,4 mmol/l« | – (auch im Original nicht OCR-lesbar) | ✗ | negativer Wert |
| »-2,0–3,0« | ✓ | ✓ | Referenzbereich mit Minus |
| »88 mg/dl« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »7,8 %« | ✓ | ✗ |  |
| »<5,7« | ✓ | ✓ |  |
| »05.02.2026, 07:30 Uhr« | ✓ | ✓ | klinische Datumsangabe (kein Geburtsdatum) |

\* »OCR-Toleranz«: Die Erkennung brauchte die Toleranzstufe für degradierte Scans (einzelne Buchstabenfehler, z. B. durch Unschärfe; alle Ziffern weiterhin exakt in Reihenfolge). Die Pixel außerhalb der Schwärzungen sind im Export nachweislich unverändert (mittlere Pixelabweichung 0,000) – die Grenze liegt hier in der Quell-Scanqualität, nicht im Export.

### Einschränkungen

- »9,6 /nl« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »248 /nl« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »139 mmol/l« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »3,4 mmol/l 3,5–5,1« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »0,9 mg/dl« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »38 mg/dl« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »Base Excess -2,4 mmol/l« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »88 mg/dl« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)

## `F03-medikationsplan.pdf`

- Exportdatei: `PV-5F6211EF-r1.pdf` (SHA-256 `e6480fedc2d7988c…`)
- Original: 41881 B → Export: 216550 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 4, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-5F6211EF-r1.pdf« enthält nichts vom Originalnamen »F03-medikationsplan.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 3 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 3 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 12 geprüft; davon 4 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »500 mg« | ✓ | ✓ | Dosierung |
| »1-0-1« | ✓ | ✓ | Einnahmeschema |
| »100 mg« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »0-1-0« | – (auch im Original nicht OCR-lesbar) | ✗ |  |
| »75 µg« | – (auch im Original nicht OCR-lesbar) | ✗ | Mikrogramm-Dosierung |
| »0-0-1/2« | ✓ | ✗ | Schema mit halber Tablette |
| »10 mg« | ✓ | ✓ |  |
| »1-0-0« | ✓ | ✓ |  |
| »15.01.2026« | ✓ | ✓ | Startdatum (klinisch) |
| »20.03.2026« | – (auch im Original nicht OCR-lesbar) | ✗ | Startdatum (klinisch) |
| »Keine Penicillinallergie bekannt.« | ✓ | ✓ | klinisch relevante Verneinung |
| »Kein Marcumar.« | ✓ | ✓ | klinisch relevante Verneinung |

### Einschränkungen

- »100 mg« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »0-1-0« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »75 µg« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)
- »20.03.2026« auch im Original nicht OCR-lesbar (Einschränkung, kein Auditfehler)

## `F04-scan.pdf`

- Exportdatei: `PV-9D835073-r1.pdf` (SHA-256 `e1bb0df3f18d3ea7…`)
- Original: 824228 B → Export: 3905765 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 9, manuell (manualOnly): 1, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-9D835073-r1.pdf« enthält nichts vom Originalnamen »F04-scan.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 5 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 5 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 4 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »05.02.2026« | ✓ | ✓ | klinisches Datum (nicht Geburtsdatum) |
| »Verlaufskontrolle Diabetes mellitus Typ 2« | ✓ | ✓ | Veranlassung |
| »HbA1c 7,8 %« | ✓ | ✓ | Laborwert |
| »142/86 mmHg« | ✓ | ✓ | Blutdruck |

## `F05-rotation-beschnitt.pdf`

- Exportdatei: `PV-BE0541A5-r1.pdf` (SHA-256 `cea001c192b99f28…`)
- Original: 32920 B → Export: 614268 B (300 dpi, 4 Seiten)
- Schwärzungen: automatisch übernommen: 17, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000, S.2 0.000, S.3 0.000, S.4 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 2: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 3: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 4: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-BE0541A5-r1.pdf« enthält nichts vom Originalnamen »F05-rotation-beschnitt.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 10 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 4 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 841x595, S.2 595x841, S.3 435x762, S.4 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 9 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 7 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »132 mg/dl« | ✓ | ✓ | Blutzucker |
| »138/82 mmHg« | ✓ | ✓ | Blutdruck |
| »7,2 %« | ✓ | ✓ | HbA1c |
| »Keine Hypoglykämie« | ✓ | ✓ | klinisch relevante Verneinung |
| »0,9 mg/dl« | ✓ | ✓ | Kreatinin |
| »-2,4 mmol/l« | ✓ | ✓ | negativer Base Excess |
| »500 mg« | ✓ | ✓ | Dosierung |

## `F06-gemischt.pdf`

- Exportdatei: `PV-D6C74AA8-r1.pdf` (SHA-256 `7a1e63d8166bcb02…`)
- Original: 1417152 B → Export: 5043161 B (300 dpi, 3 Seiten)
- Schwärzungen: automatisch übernommen: 9, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000, S.2 0.000, S.3 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 2: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).
  - Seite 3: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-D6C74AA8-r1.pdf« enthält nichts vom Originalnamen »F06-gemischt.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 8 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 3 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841, S.2 595x841, S.3 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 8 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 8 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »150/95 mmHg« | ✓ | ✓ | Blutdruck |
| »112 mg/dl« | ✓ | ✓ | Blutzucker |
| »-1,8 mmol/l« | ✓ | ✓ | negativer Wert |
| »05.02.2026« | ✓ | ✓ | klinisches Datum |
| »05.02.2026, 22:15 Uhr« | ✓ | ✓ | klinisches Datum mit Uhrzeit |
| »Blutdruck 150/95 mmHg« | ✓ | ✓ | Blutdruck |
| »132/84 mmHg« | ✓ | ✓ | Blutdruck |
| »7,4 %« | ✓ | ✓ | HbA1c |

## `F07-versteckt.pdf`

- Exportdatei: `PV-E16A4E45-r1.pdf` (SHA-256 `4b874555d7e9baa4…`)
- Original: 42595 B → Export: 194915 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 3, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-E16A4E45-r1.pdf« enthält nichts vom Originalnamen »F07-versteckt.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 12 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 0 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 5 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »7,2 %« | ✓ | ✓ | HbA1c |
| »128/78 mmHg« | ✓ | ✓ | Blutdruck |
| »0,9 mg/dl« | ✓ | ✓ | Kreatinin |
| »-1,8 mmol/l« | ✓ | ✓ | negativer Base Excess |
| »Kontrolle ist in vier Wochen geplant« | ✓ | ✓ | klinische Empfehlung |

## `F08-schlechter-scan.pdf`

- Exportdatei: `PV-182752DA-r1.pdf` (SHA-256 `3ef44a5353523832…`)
- Original: 562009 B → Export: 6575886 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 4, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-182752DA-r1.pdf« enthält nichts vom Originalnamen »F08-schlechter-scan.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 3 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 3 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 5 geprüft; davon 0 auch im Original nicht lesbar, 1 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »RR 142/86 mmHg« | ✓ | ✓ | Blutdruck |
| »HbA1c 7,8 %« | ✓ | ✓ | Laborwert |
| »Metformin 500 mg 1-0-1« | ✓ | ✓ | Dosierung und Schema |
| »Diabetes mellitus Typ 2« | ✓ (OCR-Toleranz*) | ✓ | Diagnose |
| »05.02.2026« | ✓ | ✓ | klinisches Datum |

\* »OCR-Toleranz«: Die Erkennung brauchte die Toleranzstufe für degradierte Scans (einzelne Buchstabenfehler, z. B. durch Unschärfe; alle Ziffern weiterhin exakt in Reihenfolge). Die Pixel außerhalb der Schwärzungen sind im Export nachweislich unverändert (mittlere Pixelabweichung 0,000) – die Grenze liegt hier in der Quell-Scanqualität, nicht im Export.

## `F09-ohne-identifikatoren.pdf`

- Exportdatei: `PV-B53B9E5D-r1.pdf` (SHA-256 `aa6088d8824566d5…`)
- Original: 35044 B → Export: 216561 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 0, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-B53B9E5D-r1.pdf« enthält nichts vom Originalnamen »F09-ohne-identifikatoren.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 0 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 0 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 10 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »05.01.2026« | ✓ | ✓ | klinisches Datum – darf nicht geschwärzt werden |
| »02.02.2026« | ✓ | ✓ | klinisches Datum |
| »7,8 %« | ✓ | ✓ |  |
| »7,2 %« | ✓ | ✓ |  |
| »7,0 %« | ✓ | ✓ |  |
| »0,9 mg/dl« | ✓ | ✓ |  |
| »0,8 mg/dl« | ✓ | ✓ |  |
| »142/86 mmHg« | ✓ | ✓ |  |
| »128/78 mmHg« | ✓ | ✓ |  |
| »-2,4 mmol/l« | ✓ | ✓ | negativer Wert |

## `F10c-manipulativ.pdf`

- Exportdatei: `PV-44A2F476-r1.pdf` (SHA-256 `4655db5919365f9a…`)
- Original: 28558 B → Export: 192311 B (300 dpi, 1 Seiten)
- Schwärzungen: automatisch übernommen: 4, manuell (manualOnly): 0, korrigierte Übersehene: 0
- ExportValidator (C06): **bestanden**
- Mittlere Pixelabweichung je Seite (außerhalb der Schwärzungen): S.1 0.000
  - Seite 1: mittlere Pixelabweichung außerhalb der Schwärzungen: 0.000 (Grenzwert 1.0).

| Prüfung | Ergebnis | Detail |
|---|---|---|
| C02 Original-Hash unverändert | ✓ | SHA-256 identisch vor Analyse, nach Analyse und nach Export |
| C02 neutraler Exportname | ✓ | »PV-44A2F476-r1.pdf« enthält nichts vom Originalnamen »F10c-manipulativ.pdf« |
| C04 keine Textebene | ✓ | PDFKit-Extraktion liefert keinen Text |
| C04 keine Formulare/Annotationen/Anhänge | ✓ | Annotationen: 0, Formular: nein, EmbeddedFiles: nein, Outlines: nein, OpenAction: nein, verschlüsselt: nein |
| C03/C04 keine Identifikatoren in Text/Metadaten/Struktur | ✓ | alle 3 annotierten Identifikatoren (inkl. versteckter) nicht enthalten |
| C05 Seitenzahl erhalten | ✓ | 1 Seite(n) wie im Original |
| C05 Orientierung je Seite erhalten | ✓ | S.1 595x841 |
| C03 keine Identifikator-Reste in der Export-OCR | ✓ | keine der 3 sichtbaren Identifikatoren erkannt |
| C05 Pflichtangaben in der Export-OCR lesbar | ✓ | 3 geprüft; davon 0 auch im Original nicht lesbar, 0 nur mit OCR-Toleranz |

### Pflichtangaben (B05/C05) in der Export-OCR

| Text | im Export lesbar | im Original lesbar | Hinweis |
|---|---|---|---|
| »142/86 mmHg« | ✓ | ✓ |  |
| »7,8 %« | ✓ | ✓ |  |
| »05.02.2026« | ✓ | ✓ | klinisches Datum |

## Methodik

- Der Export läuft ausschließlich über die geteilte Pipeline (`DocumentPipeline.export`) mit simulierter Freigabe: alle Sperrlisten-/Regel-Fundstellen akzeptiert, je manualOnly-Annotation eine manuelle Fundstelle, plus manuelle Fundstellen für jede übersehene sichtbare Identifikator-Stelle.
- Geprüft wird unabhängig vom `ExportValidator`: `ExportInspector`, eigene Text-/Byte-/OCR-Prüfungen, Seitenzahl und angezeigte Orientierung über CGPDFDocument.
- OCR-Vergleich: Export-Seiten und Original-Renders werden mit derselben Engine (Vision, 300 dpi) erkannt; Pflichtangaben, die schon im Original-Render nicht lesbar sind, gelten als Einschränkung, nicht als Auditfehler.
- Die negative Kontrolle zeigt, dass eine bloße schwarze Annotation (keine Rasterung) die C03-Prüfung nicht besteht.

## Grenzwertige OCR-Erkennung (degradierte Scans)

- »13,8 g/dl«: nur mit OCR-Toleranzstufe als lesbar gewertet (Vision erkennt auf dem absichtlich verschleierten Scan einzelne Buchstaben pro Lauf unterschiedlich; alle Ziffern bleiben exakt erhalten, die Pixel außerhalb der Schwärzungen sind unverändert).
- »Diabetes mellitus Typ 2«: nur mit OCR-Toleranzstufe als lesbar gewertet (Vision erkennt auf dem absichtlich verschleierten Scan einzelne Buchstaben pro Lauf unterschiedlich; alle Ziffern bleiben exakt erhalten, die Pixel außerhalb der Schwärzungen sind unverändert).
