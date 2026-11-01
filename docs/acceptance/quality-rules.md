# PaperVeil – Qualitätsbericht Erkennung (`pv-eval report`)

- **Datum:** 2026-11-01T17:24:58Z
- **Git-Commit:** `8cbaf8783dba9c2a8c0134ad352be329a96edadf`
- **Betriebssystem:** macOS Version 27.2 (Build 26B123)
- **Werkzeugkette:** Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
- **Testsatz:** /Users/piotr/git/paperveil/Fixtures/synthetic – Schema-Version 1, Generator pv-fixtures, logisches Fixturedatum 2026-02-05
- **Sperrliste:** `/Users/piotr/git/paperveil/Fixtures/synthetic/blocklist.json` – 19 fiktive Einträge
- **LLM:** nicht ausgeführt (kein `--llm-model` angegeben)

> **Ergebnisse gelten nur für diesen synthetischen Testsatz und sind keine allgemeine Erkennungsquote.**

## Pflicht-Regressionssatz (Gate)

| Regel | Ergebnis |
|---|---|
| (a) Eingabe-Ergebnis je Dokument entspricht expectedInputOutcome | bestanden |
| (b) Sperrliste+Regeln finden jede sichtbare, erwartbare Identifikator-Stelle | bestanden |
| (c) Keine klinischen Fehlalarme durch Sperrliste+Regeln (B05) | bestanden |
| (d) Fehlalarmkontrolle F09 ohne Fundstellen (Sperrliste+Regeln) | bestanden |

## Eingabeprüfung (alle Dokumente)

| Dokument | erwartet | tatsächlich | Ergebnis |
|---|---|---|---|
| `F01-arztbrief.pdf` | ok | ok | ✓ |
| `F02-laborblatt.pdf` | ok | ok | ✓ |
| `F03-medikationsplan.pdf` | ok | ok | ✓ |
| `F04-scan.pdf` | ok | ok | ✓ |
| `F05-rotation-beschnitt.pdf` | ok | ok | ✓ |
| `F06-gemischt.pdf` | ok | ok | ✓ |
| `F07-versteckt.pdf` | ok | ok | ✓ |
| `F08-schlechter-scan.pdf` | ok | ok | ✓ |
| `F09-ohne-identifikatoren.pdf` | ok | ok | ✓ |
| `F10a-beschaedigt.pdf` | damaged | damaged | ✓ |
| `F10b-verschluesselt.pdf` | encrypted | encrypted | ✓ |
| `F10c-manipulativ.pdf` | ok | ok | ✓ |

## Metriken je Verfahren und Kategorie (Rohzählungen)

### Sperrliste (blocklist.json)

| Kategorie | TP | FN | FP | TP/Anzahl* |
|---|---:|---:|---:|---|
| address | 4 | 0 | 0 | 4/4 |
| birthDate | 9 | 0 | 0 | 9/9 |
| email | 1 | 0 | 0 | 1/1 |
| insuranceNumber | 8 | 0 | 0 | 8/9 |
| name | 18 | 0 | 1 | 18/19 |
| patientID | 2 | 0 | 0 | 2/2 |
| phone | 2 | 0 | 1 | 2/2 |
| **Gesamt** | **44** | **0** | **2** | **44/46** |

\* Quote nur für diesen Testsatz, keine allgemeine Erkennungsquote.

### Regeln (RuleDetector)

| Kategorie | TP | FN | FP | TP/Anzahl* |
|---|---:|---:|---:|---|
| address | 4 | 0 | 6 | 4/4 |
| birthDate | 6 | 3 | 0 | 6/9 |
| email | 1 | 0 | 2 | 1/1 |
| insuranceNumber | 8 | 0 | 0 | 8/9 |
| name | 16 | 2 | 0 | 16/19 |
| patientID | 2 | 0 | 0 | 2/2 |
| phone | 2 | 0 | 3 | 2/2 |
| **Gesamt** | **39** | **5** | **11** | **39/46** |

\* Quote nur für diesen Testsatz, keine allgemeine Erkennungsquote.

### Kombiniert (Sperrliste+Regeln, wie die Pipeline)

| Kategorie | TP | FN | FP | TP/Anzahl* |
|---|---:|---:|---:|---|
| address | 4 | 0 | 6 | 4/4 |
| birthDate | 9 | 0 | 0 | 9/9 |
| email | 1 | 0 | 2 | 1/1 |
| insuranceNumber | 8 | 0 | 0 | 8/9 |
| name | 18 | 0 | 1 | 18/19 |
| patientID | 2 | 0 | 0 | 2/2 |
| phone | 2 | 0 | 3 | 2/2 |
| **Gesamt** | **44** | **0** | **12** | **44/46** |

\* Quote nur für diesen Testsatz, keine allgemeine Erkennungsquote.

## Details je Dokument

### `F01-arztbrief.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 3 Seite(n) ✓
- Seiten: 3; Extraktions-Warnungen: keine
- Sperrliste: 18 Fundstellen (TP 12, FN 0, FP 1)
- Regeln: 16 Fundstellen (TP 11, FN 1, FP 4)
- Kombiniert (Sperrliste+Regeln): 21 Fundstellen (TP 12, FN 0, FP 5)
- **FP Sperrliste:**
  - S. 3, name, blocklist: »Max Beispielmann«
- **FN Regeln:**
  - F01-01 (S. 1, name): »Erika Mustermann«
- **FP Regeln:**
  - S. 1, address, rule: »Musterstraße 1«
  - S. 1, address, rule: »23456 Beispielhafen«
  - S. 1, phone, rule: »+49 30 9876543«
  - S. 1, email, rule: »info@musterklinik.example.org«
- **FP Kombiniert (Sperrliste+Regeln):**
  - S. 3, name, blocklist: »Max Beispielmann«
  - S. 1, address, rule: »Musterstraße 1«
  - S. 1, address, rule: »23456 Beispielhafen«
  - S. 1, phone, rule: »+49 30 9876543«
  - S. 1, email, rule: »info@musterklinik.example.org«

### `F02-laborblatt.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: keine
- Sperrliste: 3 Fundstellen (TP 2, FN 0, FP 0)
- Regeln: 4 Fundstellen (TP 2, FN 0, FP 2)
- Kombiniert (Sperrliste+Regeln): 5 Fundstellen (TP 2, FN 0, FP 2)
- **FP Regeln:**
  - S. 1, address, rule: »Musterweg 3«
  - S. 1, address, rule: »23456 Beispielhafen«
- **FP Kombiniert (Sperrliste+Regeln):**
  - S. 1, address, rule: »Musterweg 3«
  - S. 1, address, rule: »23456 Beispielhafen«

### `F03-medikationsplan.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: keine
- Sperrliste: 4 Fundstellen (TP 3, FN 0, FP 0)
- Regeln: 3 Fundstellen (TP 3, FN 0, FP 0)
- Kombiniert (Sperrliste+Regeln): 4 Fundstellen (TP 3, FN 0, FP 0)

### `F04-scan.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: 
  - S. 1: [ocrOnlyPage] Text dieser Seite stammt aus OCR und ist abgeleitet.
- Sperrliste: 5 Fundstellen (TP 4, FN 0, FP 0)
- Regeln: 8 Fundstellen (TP 3, FN 1, FP 4)
- Kombiniert (Sperrliste+Regeln): 9 Fundstellen (TP 4, FN 0, FP 4)
- **FN Regeln:**
  - F04-02 (S. 1, birthDate): »05.11.1958«
- **FP Regeln:**
  - S. 1, address, rule: »Musterweg 3«
  - S. 1, address, rule: »23456 Beispielhafen«
  - S. 1, phone, rule: »+49 30 9876543«
  - S. 1, email, rule: »musterklinik@example.org«
- **FP Kombiniert (Sperrliste+Regeln):**
  - S. 1, address, rule: »Musterweg 3«
  - S. 1, address, rule: »23456 Beispielhafen«
  - S. 1, phone, rule: »+49 30 9876543«
  - S. 1, email, rule: »musterklinik@example.org«
- **Manuell zu schwärzen (manualOnly):**
  - F04-05 (S. 1, image): »QR-Code (Inhalt: PATIENT=Y987654321;GEB=05.11.1958;N=MAX BEISPIELMANN;SYNTHETIC)«

### `F05-rotation-beschnitt.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 4 Seite(n) ✓
- Seiten: 4; Extraktions-Warnungen: keine
- Sperrliste: 14 Fundstellen (TP 9, FN 0, FP 1)
- Regeln: 11 Fundstellen (TP 9, FN 0, FP 1)
- Kombiniert (Sperrliste+Regeln): 17 Fundstellen (TP 9, FN 0, FP 1)
- **FP Sperrliste:**
  - S. 4, phone, blocklist: »+49 30 1234567«
- **FP Regeln:**
  - S. 4, phone, rule: »+49 30 1234567«
- **FP Kombiniert (Sperrliste+Regeln):**
  - S. 4, phone, blocklist: »+49 30 1234567«
- **Versteckte Identifikatoren (keine Erkennungsziele, abgedeckt durch Export, C04):**
  - F05-08 (S. 3, insuranceNumber, Kanal outsideCropBox): »X123456789«

### `F06-gemischt.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 3 Seite(n) ✓
- Seiten: 3; Extraktions-Warnungen: 
  - S. 2: [ocrOnlyPage] Text dieser Seite stammt aus OCR und ist abgeleitet.
  - S. 2: [lowOCRConfidence] Unsichere OCR-Erkennung auf dieser Seite (geringste Konfidenz 0,3 < 0,5). Bitte Text manuell prüfen.
- Sperrliste: 9 Fundstellen (TP 8, FN 0, FP 0)
- Regeln: 8 Fundstellen (TP 7, FN 1, FP 0)
- Kombiniert (Sperrliste+Regeln): 9 Fundstellen (TP 8, FN 0, FP 0)
- **FN Regeln:**
  - F06-06 (S. 2, birthDate): »05.11.1958«

### `F07-versteckt.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: keine
- Sperrliste: 3 Fundstellen (TP 0, FN 0, FP 0)
- Regeln: 1 Fundstellen (TP 0, FN 0, FP 0)
- Kombiniert (Sperrliste+Regeln): 3 Fundstellen (TP 0, FN 0, FP 0)
- Fundstellen auf versteckte/manuelle Annotationen (Sperrliste): 3
- Fundstellen auf versteckte/manuelle Annotationen (Regeln): 1
- Fundstellen auf versteckte/manuelle Annotationen (Kombiniert (Sperrliste+Regeln)): 3
- **Versteckte Identifikatoren (keine Erkennungsziele, abgedeckt durch Export, C04):**
  - F07-01 (S. 1, name, Kanal invisibleText): »Erika Mustermann«
  - F07-02 (S. 1, insuranceNumber, Kanal invisibleText): »X123456789«
  - F07-03 (S. 1, name, Kanal metadata): »Erika Mustermann«
  - F07-04 (S. 1, insuranceNumber, Kanal metadata): »X123456789«
  - F07-05 (S. 1, name, Kanal form): »Erika Mustermann«
  - F07-06 (S. 1, insuranceNumber, Kanal annotation): »X123456789«
  - F07-07 (S. 1, name, Kanal attachment): »Erika Mustermann«
  - F07-08 (S. 1, birthDate, Kanal attachment): »12.03.1967«
  - F07-09 (S. 1, address, Kanal attachment): »Musterstraße 5, 12345 Musterstadt«
  - F07-10 (S. 1, insuranceNumber, Kanal attachment): »X123456789«
  - F07-11 (S. 1, phone, Kanal attachment): »+49 30 1234567«
  - F07-12 (S. 1, email, Kanal attachment): »erika.mustermann@example.org«

### `F08-schlechter-scan.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: 
  - S. 1: [ocrOnlyPage] Text dieser Seite stammt aus OCR und ist abgeleitet.
- Sperrliste: 4 Fundstellen (TP 3, FN 0, FP 0)
- Regeln: 1 Fundstellen (TP 1, FN 2, FP 0)
- Kombiniert (Sperrliste+Regeln): 4 Fundstellen (TP 3, FN 0, FP 0)
- **FN Regeln:**
  - F08-01 (S. 1, name): »Erika Mustermann« – Kennzeichnung: Zuordnungsproblem erwartet
  - F08-02 (S. 1, birthDate): »12.03.1967«

### `F09-ohne-identifikatoren.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: keine
- Sperrliste: 0 Fundstellen (TP 0, FN 0, FP 0)
- Regeln: 0 Fundstellen (TP 0, FN 0, FP 0)
- Kombiniert (Sperrliste+Regeln): 0 Fundstellen (TP 0, FN 0, FP 0)

### `F10a-beschaedigt.pdf` (damaged)

- Eingabe: **damaged** – Die PDF-Datei ist beschädigt oder konnte nicht gelesen werden. ✓

### `F10b-verschluesselt.pdf` (encrypted)

- Eingabe: **encrypted** – Die PDF-Datei ist verschlüsselt oder durch ein Passwort geschützt. Verschlüsselte Dateien werden von PaperVeil nicht geöffnet. ✓

### `F10c-manipulativ.pdf` (ok)

- Eingabe: **ok** – Eingabe gültig, 1 Seite(n) ✓
- Seiten: 1; Extraktions-Warnungen: keine
- Sperrliste: 4 Fundstellen (TP 3, FN 0, FP 0)
- Regeln: 3 Fundstellen (TP 3, FN 0, FP 0)
- Kombiniert (Sperrliste+Regeln): 4 Fundstellen (TP 3, FN 0, FP 0)

## Einordnung und bekannte Grenzen

- Der Testsatz ist synthetisch und vollständig fiktiv; er beweist nur das Verhalten an diesen Fällen (siehe `docs/ZIELZUSTAND.md`, Abschnitt 5).
- Versteckte Identifikatoren (Metadaten, Formulare, Annotationen, Anhänge, unsichtbarer Text, außerhalb der CropBox) sind keine Erkennungsziele und werden durch den Raster-Export entfernt (C04); sie werden oben separat aufgeführt.
- Absenderdaten (Klinik/Praxis/Arzt) sind in diesem Testsatz bewusst **nicht** als Identifikatoren annotiert (`policy.clinicAndPhysicianDataIsIdentifier: false`); Fundstellen darauf werden als FP gezählt und separat ausgewiesen.
- LLM-Erkennung: **nicht ausgeführt** – dieser Bericht umfasst nur Sperrliste und Regeln.
