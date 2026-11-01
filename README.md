# PaperVeil

PaperVeil ist eine lokale macOS-App, die persönliche PDF-Dokumente – zuerst deutschsprachige
medizinische Befunde – vor der Weitergabe bereinigt. PDFs werden per Drag-and-drop importiert,
Schwärzungen werden automatisch vorgeschlagen (Sperrliste, Regeln, optional ein lokales LLM über
LM Studio), von dir geprüft und korrigiert, und erst nach deiner ausdrücklichen Freigabe als
separate, neu gerasterte Kopie gespeichert oder übertragen.

> **Keine Zusicherung:** PaperVeil garantiert weder Anonymität noch die Erkennung aller
> Identifikatoren. Ein technisch erfolgreicher Export ersetzt nicht deine eigene Datenschutzprüfung.
> Die App stellt keine Diagnosen und verändert keine medizinischen Inhalte.

Anforderungen und Abnahmekriterien: [`docs/ZIELZUSTAND.md`](docs/ZIELZUSTAND.md).
Abnahmeberichte: [`docs/acceptance/`](docs/acceptance/).

## Unterstützte Plattform

| | Version |
|---|---|
| macOS | **27.2** (Deployment-Target macOS 27; ältere Versionen werden nicht unterstützt) |
| Architektur | Apple Silicon (arm64), entwickelt auf M4 Max |
| Xcode | **27.2** (Build 27B52), Swift 6.4.2 |
| CI | GitHub-Standard-Runner `xcode-27` (macOS 27, Xcode 27) |

## Installation

### Aus dem Quellcode

```sh
git clone https://github.com/Fruitseller/paperveil.git
cd paperveil
swift test                       # alle automatisierten Tests
./scripts/build-app.sh build     # erzeugt build/PaperVeil.app und build/PaperVeil.zip
open build/PaperVeil.app
```

### Vorgebautes App-Build

Jeder CI-Lauf lädt `PaperVeil-unsigned-<commit>` als Artefakt hoch (7 Tage Aufbewahrung).

**Signierung:** Das Build ist nur **ad-hoc signiert**: keine Developer ID, keine Notarisierung.
Nach dem Herunterladen blockiert Gatekeeper den ersten Start. Freigeben so:

1. ZIP entpacken und `PaperVeil.app` nach `/Programme` ziehen.
2. Einmal öffnen, die Warnung schließen, dann *Systemeinstellungen → Datenschutz & Sicherheit →
   „Dennoch öffnen“*. Alternativ: `xattr -d com.apple.quarantine /Applications/PaperVeil.app`.

## Bedienung

1. PDFs ins Fenster ziehen oder über **+** auswählen. Jede Datei erhält eine neutrale ID (`PV-XXXXXXXX`).
   Nicht-PDFs, beschädigte, leere und verschlüsselte Dateien werden mit Fehlermeldung abgelehnt.
2. Die Verarbeitung läuft im Hintergrund (Text/OCR → Sperrliste & Regeln → optional LLM → Export).
   Jedes Dokument lässt sich abbrechen und wiederholen.
3. **Prüfen:** Links das Original mit markierten Fundstellen, in der Mitte die bereinigte Vorschau,
   rechts die Liste mit Kategorie und Herkunft (Sperrliste, Regel, LLM, manuell). Jede Fundstelle
   muss auf *schwärzen* oder *nicht schwärzen* gesetzt werden. Mit **Bereich markieren** ziehst du
   zusätzliche Rechtecke auf, auch über Bildern und QR-Codes.
4. Warnungen (z. B. LLM nicht erreichbar, erfundenes Zitat, unsichere OCR) müssen einzeln bestätigt werden.
5. **Prüfung bestätigen & Export erzeugen:** erzeugt die bereinigte Kopie und validiert sie erneut.
6. **Freigeben:** Erst jetzt gilt diese Exportrevision als übertragbar. Jede spätere Änderung hebt
   die Freigabe auf.
7. Optional **übertragen** (siehe unten).

### Statusanzeige

`Wartet` · `Verarbeitung` · `Prüfung nötig` · `Bereit zur Freigabe` · `Freigegeben` · `Übertragung` ·
`Übertragen (verifiziert)` · `Abgebrochen` · `Fehler`. Kein Status behauptet Anonymität. Nach einem
Neustart erscheinen unterbrochene Vorgänge als `Fehler` (Verarbeitung) oder als nicht übertragen.

## Wie geschwärzt wird

Jede Seite wird mit 300 dpi gerastert. Die genehmigten Bereiche werden **in den Pixeln** schwarz
gefüllt, und aus diesen Bildern entsteht eine **neue** PDF. Text, Metadaten, Formulare,
Annotationen, Anhänge oder verborgene Ebenen des Originals werden nicht übernommen. Jeder Export
wird erneut geöffnet und geprüft:

- Seitenzahl und Orientierung
- keine Textebene
- keine Annotationen, Formulare oder Anhänge
- neutrale Metadaten
- Masken schwarz
- Bildvergleich außerhalb der Masken

Fehlgeschlagene Exporte können nicht freigegeben werden. Folgen: Der Export hat **keine
durchsuchbare Textebene** und ist größer als das Original.

## Lokales LLM (optional, LM Studio)

1. [LM Studio](https://lmstudio.ai) installieren, ein Modell laden und unter *Developer* den lokalen
   Server starten (Standard `http://127.0.0.1:1234`), oder per CLI: `lms server start`.
2. In PaperVeil unter *Einstellungen → Lokales LLM* aktivieren und das Modell aus der vom Server
   gemeldeten Liste wählen. Modell-IDs werden vom Server abgefragt, nicht aus Dateinamen abgeleitet.
3. Nur Loopback-Adressen (`127.0.0.1`, `::1`, `localhost`) sind zulässig. Es gibt keinen Cloud-Fallback.

Das LLM liefert nur Zitate und Kategorien. Jedes Zitat wird gegen den Originaltext und die Geometrie
geprüft. Erfundene, mehrdeutige oder ungültige Antworten sowie Timeouts erzeugen Warnungen, die die
Freigabe sperren. Ohne LLM funktionieren Sperrliste, Regeln und die manuelle Prüfung weiter.

## Lokale Daten

| Ort | Inhalt |
|---|---|
| `~/Library/Application Support/PaperVeil/jobs.json` | Warteschlange, Fundstellen (enthalten erkannte Identifikatoren!), Freigabe- und Transferstatus |
| `~/Library/Application Support/PaperVeil/work/<ID>/` | bereinigte Exporte (`<ID>-r<Revision>.pdf`) |
| `~/Library/Application Support/PaperVeil/blocklist.json` | persönliche Sperrliste |
| `~/Library/Application Support/PaperVeil/settings.json` | nicht geheime Einstellungen |
| `~/Library/Application Support/PaperVeil/known_hosts` | bestätigte Hostschlüssel des Empfängers |
| macOS-Schlüsselbund (Dienst `de.paperveil`) | geheime Einstellungen |

Originale bleiben, wo sie sind, und werden nur gelesen. Löschen: Kontextmenü *Aus Liste entfernen
und Arbeitsdaten löschen* oder *Einstellungen → Daten → Alle lokalen Daten löschen*.

**Verschlüsselung:** PaperVeil verschlüsselt seine Dateien nicht selbst. Schutz im Ruhezustand bietet FileVault, das aktiviert sein sollte.

**Grenzen:** Löschen entfernt Dateien über das Dateisystem. Kopien in Time Machine, Snapshots,
iCloud-Synchronisierung des Ordners oder auf SSD-Ebene bleiben möglicherweise bestehen. Eine sichere
physische Löschung wird nicht versprochen. Logs (`log stream --predicate 'subsystem == "de.paperveil.app"'`)
enthalten nur Dokument-IDs und Phasen, keine Befundtexte oder Identifikatoren.

## Übertragung (optional)

Übertragen werden nur **freigegebene** Exportrevisionen, per SSH mit festgelegter Serveridentität:

- Der Empfänger installiert `receiver/paperveil-receive` als *forced command* für einen eigenen,
  unprivilegierten Benutzer (Anleitung: [`receiver/README.md`](receiver/README.md)).
- Der Hostschlüssel wird einmal abgerufen, als Fingerabdruck angezeigt und erst nach deiner
  Bestätigung gespeichert. Ein unbekannter oder geänderter Schlüssel bricht die Übertragung ab.
- Der Server schreibt zuerst in eine temporäre Datei, prüft SHA-256 und Größe und finalisiert dann
  atomar, ohne zu überschreiben. Erst seine Bestätigung `OK <Name> <SHA-256>` markiert das Dokument
  als *übertragen (verifiziert)*.
- Übertragen werden nur die bereinigte PDF und ihr neutraler Dateiname. Originale, Sperrliste,
  Fundstellen und Logs werden nie übertragen.

Ein erfolgreicher Upload löst keine weitere Verarbeitung aus, etwa eine Cloud-Analyse.

## Fehlerbehandlung

| Situation | Verhalten |
|---|---|
| Nicht-PDF, beschädigt, leer, verschlüsselt | Status *Fehler* mit Begründung, nie uploadbereit |
| LLM nicht erreichbar / Timeout / ungültige Antwort | Warnung, Freigabe gesperrt bis zur Bestätigung |
| Unsichere OCR | Warnung je Seite; OCR-Text gilt als abgeleitet |
| Export-Validierung fehlgeschlagen | Warnung, keine Freigabe möglich |
| Abbruch / App-Neustart während Verarbeitung | *Abgebrochen* bzw. *Fehler: unterbrochen*, Wiederholung möglich |
| Upload abgebrochen, Prüfsumme falsch, keine Schreibrechte, Hostschlüssel unbekannt | *Übertragung fehlgeschlagen*, nie *übertragen* |

## Bekannte Grenzen

- Übersehene Identifikatoren sind möglich, besonders bei unbekannten Layouts, Handschrift und schlechten Scans.
- Exporte haben keine Textebene (keine Suche, kein Kopieren); eine optionale OCR-Ebene ist noch nicht umgesetzt.
- Die Sprache ist Deutsch; andere Sprachen sind nicht getestet.
- Nicht signiert oder notarisiert (siehe oben).

## Entwicklung

```sh
swift test                                            # Unit- und Integrationstests (LLM: SIMULIERTE Antworten)
swift run pv-fixtures Fixtures/synthetic              # synthetischen Testsatz neu erzeugen
swift run pv-eval report --fixtures Fixtures/synthetic --out report.md            # Qualitätsbericht ohne LLM
swift run pv-eval report --fixtures Fixtures/synthetic --llm-model <id> --out r.md # mit lokalem LM-Studio-Modell
PAPERVEIL_LMSTUDIO_TEST=1 swift test --filter LMStudio # echter LM-Studio-Test (lokal, nicht in CI)
sh receiver/test-receiver.sh                          # Tests des Empfangsskripts
```

Module: `PaperVeilCore` (Modell, Status, Speicherung), `PaperVeilExtraction` (PDFKit, Vision-OCR),
`PaperVeilDetection` (Sperrliste, Regeln, LM Studio), `PaperVeilExport` (Rasterexport, Validierung),
`PaperVeilTransfer` (SSH-Transfer, Hostschlüssel, Schlüsselbund), `PaperVeilApp` (SwiftUI).

### CI und Kosten

Die CI nutzt nur GitHub-Standard-Runner (`xcode-27`, `ubuntu-latest`), keine kostenpflichtigen
*Larger Runner* und keine externen Modell-APIs. Artefakte werden 7 Tage aufbewahrt, Caches werden
nicht verwendet. Für öffentliche Repositories sind Standard-Runner derzeit kostenlos; das kann
GitHub ändern. Workflow-Token haben nur `contents: read`, und es werden keine Secrets verwendet.
Pull Requests aus Forks erhalten deshalb keinen Zugang zu Release-Secrets, Mac, NAS oder Empfangsserver.

## Herkunft, KI-Unterstützung und Lizenz

PaperVeil steht unter der [MIT-Lizenz](LICENSE). Der Code wurde mit KI-Unterstützung geschrieben
(Claude Code / Claude Opus und GLM 5.3 über OpenCode) und vom Maintainer geprüft. Die MIT-Datei
regelt die Nutzung. Sie ist kein Nachweis, dass jede Zeile von einer bestimmten Person stammt.

Abhängigkeiten: nur Apple-Systemframeworks (SwiftUI, PDFKit, Vision, CoreGraphics, CryptoKit,
Security) sowie die im System vorhandenen OpenSSH-Werkzeuge (`ssh`, `ssh-keyscan`, `ssh-keygen`).
Es gibt keine Drittanbieter-Pakete. LM Studio ist eine separate, optionale Anwendung mit eigener
Lizenz und wird nicht mitgeliefert.

Sicherheitsprobleme bitte vertraulich melden: siehe [SECURITY.md](SECURITY.md).
