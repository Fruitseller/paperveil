# PaperVeil

Lokale macOS-App, die PDF-Befunde vor der Weitergabe schwärzt. Sie schlägt Schwärzungen vor
(Sperrliste, Regeln, optional ein lokales LLM). Du prüfst sie, und erst nach deiner Freigabe
entsteht eine neue, bereinigte Kopie.

> PaperVeil garantiert keine Anonymität. Die eigene Prüfung vor der Freigabe bleibt nötig.

Anforderungen: [`docs/ZIELZUSTAND.md`](docs/ZIELZUSTAND.md) · Abnahme: [`docs/acceptance/`](docs/acceptance/)

## Voraussetzungen

- macOS 27.2 auf Apple Silicon (ältere Versionen werden nicht unterstützt)
- Xcode 27.2 (zum Bauen)
- optional [LM Studio](https://lmstudio.ai) für die LLM-Erkennung

## Installation

```sh
git clone https://github.com/Fruitseller/paperveil.git && cd paperveil
./scripts/build-app.sh build
open build/PaperVeil.app
```

Fertige Builds liegen als CI-Artefakt `PaperVeil-unsigned-<commit>` bereit (7 Tage). Sie sind nur
ad-hoc signiert und nicht notarisiert. Den ersten Start musst du unter *Systemeinstellungen →
Datenschutz & Sicherheit → „Dennoch öffnen“* freigeben.

## Bedienung

1. PDFs ins Fenster ziehen oder über **+** hinzufügen. Jede Datei erhält eine neutrale ID.
2. Fundstellen prüfen: jeweils *schwärzen* oder *nicht schwärzen*. Mit **Bereich markieren**
   schwärzt du zusätzliche Flächen.
3. Warnungen bestätigen, dann **Prüfung bestätigen & Export erzeugen**.
4. **Freigeben**. Jede spätere Änderung hebt die Freigabe auf.
5. Optional **übertragen**.

Unlesbare Dateien, LLM-Ausfälle, unsichere OCR und fehlgeschlagene Exporte oder Übertragungen
erscheinen mit Begründung als Fehler oder Warnung. Bis du sie bestätigt hast, ist keine Freigabe
möglich.

Der Export ist eine neue PDF aus gerasterten Seiten (300 dpi). Die Schwärzungen sind in den
Pixeln, Text, Metadaten, Formulare und Anhänge werden nicht übernommen. Er hat deshalb keine
Textebene. Jeder Export wird vor der Freigabe automatisch geprüft.

## Lokales LLM

In LM Studio ein Modell laden und den Server starten (`lms server start`). Dann in PaperVeil unter
*Einstellungen → Lokales LLM* das Modell wählen. Nur Adressen auf dem eigenen Rechner sind
erlaubt; es gibt keinen Cloud-Fallback. Fällt das LLM aus, sperrt eine Warnung die Freigabe.

## Übertragung

Übertragen werden nur freigegebene Exporte, per SSH an `receiver/paperveil-receive` auf dem
Empfänger ([Einrichtung](receiver/README.md)). Den Hostschlüssel bestätigst du einmal. Der
Empfänger prüft die SHA-256-Prüfsumme, und erst danach gilt die Datei als übertragen.

## Lokale Daten

Alles liegt in `~/Library/Application Support/PaperVeil/`. Geheime Einstellungen speichert die App
im Schlüsselbund. Originale werden nur gelesen. Löschen kannst du über das Kontextmenü oder unter
*Einstellungen → Daten*. Kopien in Backups bleiben davon unberührt; aktiviere FileVault.

## Grenzen

- Identifikatoren können übersehen werden, besonders in schlechten Scans und unbekannten Layouts.
- Getestet ist nur Deutsch.
- Exporte haben keine durchsuchbare Textebene.

## Entwicklung

```sh
swift test                                              # Tests (LLM-Antworten simuliert)
swift run pv-eval report --fixtures Fixtures/synthetic --out report.md
```

Die CI läuft auf GitHub-Standard-Runnern. Vision-OCR funktioniert dort nicht, deshalb laufen die
OCR-Prüfungen nur lokal.

## Lizenz

[MIT](LICENSE). Mit KI-Unterstützung entwickelt. Abhängigkeiten sind nur Apple-Frameworks und das
System-OpenSSH. Sicherheitsprobleme bitte vertraulich melden: [SECURITY.md](SECURITY.md).
