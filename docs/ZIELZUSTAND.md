# PaperVeil – Zielzustand und verifizierbare Abnahme

## 1. Zweck und Status

PaperVeil ist eine lokale macOS-App, die persönliche PDF-Dokumente vor ihrer Weitergabe bereinigt. Der erste Anwendungsfall sind deutschsprachige medizinische Befunde. Nutzer ziehen PDFs in die App, erhalten automatisch vorgeschlagene Schwärzungen, prüfen und korrigieren das Ergebnis und geben eine separate bereinigte Kopie zur lokalen Speicherung oder Übertragung frei.

Dieses Dokument beschreibt Anforderungen, keine bereits vorhandenen Funktionen. Alle Kriterien sind zunächst **offen**. Ein Commit dieses Dokuments, ein erfolgreicher Build oder eine attraktive Oberfläche bedeutet nicht, dass das Produkt abgenommen ist.

**Erfolg:** Der in Abschnitt 6 definierte Abnahmelauf gelingt mit dokumentierten Ergebnissen auf einem unterstützten Mac. Die App schützt Originale, entfernt die freigegebenen Inhalte tatsächlich, erhält die übrigen medizinischen Inhalte und überträgt ausschließlich ausdrücklich freigegebene Ergebnisse.

**Keine Zusicherung:** PaperVeil garantiert weder Anonymität noch die Erkennung aller Identifikatoren. Technisch erfolgreicher Export und menschliche Datenschutzprüfung sind unterschiedliche Schritte. Die App diagnostiziert nicht und verändert keine Behandlungen.

## 2. Produkt- und Architekturentscheidungen

- Native Oberfläche mit **SwiftUI**. PDFKit ist für Anzeige, Geometrie und Extraktion vorgesehen, Apple Vision für lokale OCR. Diese Komponentenwahl ersetzt keine Prüfung der Export-Sicherheit.
- Verarbeitungskern, Oberfläche, Erkennung, Exportprüfung und Übertragung sind getrennt testbar.
- Regeln und eine persönliche lokale Sperrliste übernehmen reproduzierbare Treffer. Ein lokales LLM ergänzt Fundstellen; es schreibt den medizinischen Bericht nicht um.
- **LM Studio** wird über seine lokale API angebunden. Modell-IDs werden vom tatsächlich konfigurierten Server ermittelt, nicht aus Dateinamen abgeleitet. Die vom Nutzer genannten Modelle `Ornith-1.5-35B-A3B-GGUF` und `Qwen3.8-27B-GGUF` sind Kandidaten für einen Vergleich, keine bereits getesteten Voraussetzungen oder garantierten Empfehlungen.
- Standardmäßig ist nur ein Loopback-Endpunkt für die Modellinferenz zulässig. Es gibt keinen stillen Cloud-Fallback und keine Telemetrie.
- Bevorzugter erster Exportansatz: Seiten rendern, freigegebene Bereiche in den Pixeln entfernen, neue PDF ausschließlich aus bereinigten Bildern erzeugen. Eine optionale neue Textebene darf nur aus diesen bereinigten Bildern entstehen. Ein anderer Exportansatz ist zulässig, wenn er dieselben Abnahmekriterien nachweislich erfüllt und die Entscheidung dokumentiert wird.
- Die App läuft ohne separat zu installierendes Python, Docker oder einen zusätzlichen lokalen Webserver. LM Studio ist nur für die optionale LLM-Erkennung erforderlich.
- Originale und Reidentifikationsdaten bleiben privat. NAS-Archivierung ist ein vorgesehener Einsatz, keine für den ersten Release erforderliche NAS-Integration. Der Upload-Zielordner ist konfigurierbar; private Serverdaten werden nicht im Repository festgeschrieben.

## 3. Verbindliche Abnahmekriterien

### A. Installation und Bedienung

- [ ] **A01 – Echter Mac-Build:** Ein sauberer Checkout lässt sich mit einer dokumentierten Xcode-Version auf einem ausdrücklich genannten macOS-Ziel bauen. Ein Standard-macOS-Runner führt Build und automatisierte Tests aus. Ein herunterladbares App-Build lässt sich auf einem passenden Mac starten. Signierungsstatus und gegebenenfalls notwendige manuelle Freigaben sind dokumentiert.
- [ ] **A02 – Dateieningang:** Mehrere PDFs lassen sich per Drag-and-drop und Dateiauswahl hinzufügen. Nicht-PDFs, beschädigte, leere und verschlüsselte PDFs werden verständlich behandelt; nicht lesbare Dokumente werden nicht als erfolgreich verarbeitet oder uploadbereit markiert.
- [ ] **A03 – Warteschlange:** Jede Datei hat eine neutrale Dokument-ID, einen eigenen Status, die aktuelle Verarbeitungsphase und eine Fehleranzeige. Ein langsames LLM blockiert die Oberfläche nicht. Abbruch und Wiederholung sind möglich.
- [ ] **A04 – Neustart:** Nach einem regulären Neustart bleiben Warteschlange, abgeschlossene Exporte und Freigabestatus erhalten. Ein unterbrochener Vorgang erscheint nicht fälschlich als abgeschlossen oder übertragen. Persistierte personenbezogene Arbeitsdaten bleiben lokal und sind löschbar.
- [ ] **A05 – Eindeutige Statussprache:** Die Oberfläche unterscheidet mindestens: wartet, Verarbeitung, Prüfung nötig, bereit zur Freigabe, Übertragung, übertragen/verifiziert und Fehler. Kein Status behauptet garantierte Anonymität. Bei laufender Verarbeitung ist eine finale Freigabe ausgeschlossen.

### B. Lokale Extraktion und Erkennung

- [ ] **B01 – PDF und OCR:** Sowohl auswählbarer PDF-Text als auch reine Scans werden verarbeitet. Deutsch wird getestet. Fundstellen behalten Dokument-ID, Seite und überprüfbare Seitenkoordinaten; Rotation und wiederholte Textstellen werden korrekt zugeordnet.
- [ ] **B02 – Sperrliste und Regeln:** Eine lokal verwaltete Sperrliste erkennt hinterlegte Identifikatoren und dokumentierte Varianten. Kontextregeln erkennen die festgelegten Testfälle für E-Mail, Telefonnummer, Anschrift, Geburtsdatum und Versicherungsnummer. Klinisch relevante Zahlen und Daten werden nicht pauschal entfernt.
- [ ] **B03 – LM-Studio-Anbindung:** Modellliste, gewähltes Modell, Erreichbarkeit und Fehler sind sichtbar. Ein Test mit einem realen lokalen LM-Studio-Server erzeugt korrekt zugeordnete Kandidaten. Ohne verfügbares LLM kann die App Regeln und manuelle Prüfung nutzen; ein ausgefallener angeforderter LLM-Prüfschritt wird nicht stillschweigend als erfolgreich gewertet.
- [ ] **B04 – Begrenzte LLM-Rolle:** Das Modell liefert strukturierte Fundstellen und Kategorien. Vorschläge werden gegen Originaltext und Geometrie validiert. Erfundenes Zitat, ungültige Antwort, mehrdeutige Zuordnung und Timeout führen zu einer sichtbaren Warnung beziehungsweise gesperrter Freigabe bis zur ausdrücklichen Prüfung. Dokumentanweisungen werden als Daten behandelt und können keine Werkzeuge oder Uploads auslösen.
- [ ] **B05 – Erhalt medizinischer Inhalte:** Originaltext wird nicht vom LLM neu formuliert. Freigegebene Testfälle bewahren außerhalb genehmigter Schwärzungsbereiche Werte, Dezimal- und Minuszeichen, Einheiten, Referenzbereiche, Dosierungen, Verneinungen und relevante Datumsangaben. OCR-Text ist als abgeleitet gekennzeichnet; unsichere OCR wird nicht als gesicherter Originalbefund ausgegeben.
- [ ] **B06 – Qualitätsbericht:** Ein versionierter, annotierter synthetischer Testsatz liefert je Erkennungsverfahren und Kategorie Treffer, übersehene Stellen und Fehlalarme. Ein Lauf ohne LLM und ein Lauf mit dem ausgewählten lokalen Modell werden getrennt berichtet. Der Pflicht-Regressionssatz besteht vollständig; Ergebnisse werden nicht als allgemeine Erkennungsquote für unbekannte Dokumente vermarktet.

### C. Prüfung und echte Inhaltsentfernung

- [ ] **C01 – Vorschau und Korrektur:** Original und bereinigte Vorschau sind vergleichbar. Jede Fundstelle zeigt Kategorie und Herkunft (Sperrliste, Regel, LLM oder manuell). Nutzer können Vorschläge zurücknehmen und zusätzliche Bereiche markieren, auch in Bildern. Jede inhaltliche Änderung nach Freigabe hebt diese für den neuen Export auf.
- [ ] **C02 – Originalschutz:** Kein Eingabe-PDF wird überschrieben. Hashes der Originale sind vor und nach Verarbeitung, Export, Abbruch und Wiederholung unverändert. Ausgaben haben neutrale Dateinamen ohne Originalnamen oder persönliche Kennungen.
- [ ] **C03 – Tatsächliche Entfernung:** Alle genehmigten Schwärzungsbereiche sind im Export unlesbar und nicht durch Entfernen einer Annotation oder durch Kopieren/Extraktion wiederherstellbar. Das gilt für Text-PDFs und Scans. Bloße schwarze Überlagerungen bestehen diesen Test nicht.
- [ ] **C04 – Keine geerbten Nebenkanäle:** Test-Identifikatoren in Metadaten, verborgenen Textebenen, Formularen, Annotationen und Anhängen gelangen nicht in den Export. Neue Dateien enthalten nur ausdrücklich erzeugte, bereinigte Inhalte und neutrale Metadaten. Prüfung durch erneutes Öffnen, unabhängige Textextraktion sowie Inspektion von Metadaten und PDF-Struktur; einfache Byte-Suche allein genügt nicht.
- [ ] **C05 – Exportqualität:** Seitenzahl, Reihenfolge und Orientierung bleiben erhalten. Auf den Pflicht-Testseiten ist außerhalb der Schwärzungsbereiche sämtlicher medizinisch relevanter Kleindruck in einer definierten Prüfansicht lesbar. Renderauflösung, Größenunterschiede und bekannte Einschränkungen werden im Abnahmebericht festgehalten. Ein rasterbasierter Export wird vor optionaler OCR außerhalb der Masken per Bildvergleich gegen den entsprechenden Quell-Render geprüft.
- [ ] **C06 – Exportvalidierung:** Ein fertiger Export wird erneut geöffnet und geprüft. Fehlerhafte oder unvollständige Ausgaben werden nicht freigegeben. Erkannte OCR-, Zuordnungs- und Exportprobleme erfordern eine explizite Behandlung. Das System behauptet nicht, jede mögliche Unsicherheit selbst erkennen zu können.

### D. Datenschutz und Übertragung

- [ ] **D01 – Netzwerkgrenze:** Während Verarbeitung und Export gehen Dokumentinhalte ausschließlich an den explizit konfigurierten lokalen Modellserver. Ein kontrollierter Netzwerktest zeigt keine externe Dokumentübermittlung, Telemetrie oder Cloud-Ausweichroute. Ohne konfigurierte Upload-Verbindung funktioniert lokale Verarbeitung und Speicherung offline.
- [ ] **D02 – Explizite Freigabe:** In der ersten Version gibt es keinen unbeaufsichtigten Upload. Jede Exportrevision muss vom Nutzer zur Übertragung freigegeben werden. Originale, Sperrlisten, Reidentifikationsmappings und Rohprotokolle sind vom Upload ausgeschlossen. Das Begleitmanifest enthält nur geprüfte neutrale Informationen wie Dokument-ID, Exportrevision und Prüfsumme.
- [ ] **D03 – Geschützter Transport:** Ein dokumentierter authentifizierter und verschlüsselter Transfer, bevorzugt SFTP/SSH, verwendet eine validierte Serveridentität. Ein geänderter oder unbekannter Hostschlüssel wird nicht stillschweigend akzeptiert. Zugangsdaten stehen nicht im Repository oder in Logs; geheime App-Einstellungen verwenden einen geeigneten sicheren Speicher.
- [ ] **D04 – Verifizierter Empfang:** Der Empfänger erhält zunächst einen temporären Upload. Erst nach erfolgreicher serverseitiger SHA-256-Prüfung und atomarer Finalisierung wird der exakte Zielpfad als übertragen markiert. Abbruch, voller Datenträger, falsche Prüfsumme und Verbindungsfehler erzeugen keinen finalen Erfolg. Wiederholung erzeugt keine unkontrollierten Duplikate und überschreibt keine fremden Dokumente.
- [ ] **D05 – Empfangsgrenzen:** Die Empfangsberechtigung ist auf den vorgesehenen Eingang begrenzt oder ein gleichwertiger serverseitiger Schutz wird nachgewiesen. Ein Integrationstest versucht einen Schreibzugriff außerhalb des erlaubten Bereichs und muss scheitern. Ein Hermes-Profil allein gilt nicht als Sicherheitsgrenze.
- [ ] **D06 – Keine automatische Folgefreigabe:** Ein erfolgreicher Upload löst nicht ungefragt eine Übermittlung an ein Cloud-Modell aus. Empfang und nachgelagerte Cloud-Analyse sind getrennte Freigaben. Der erste Release benötigt keine implementierte Gesundheitsanalyse.
- [ ] **D07 – Lokale Datenkontrolle:** Nutzer können Arbeitskopien, Ergebnisse und gespeicherte personenbezogene Konfiguration gezielt löschen. Originaldateien werden dabei nicht versehentlich gelöscht. Logs enthalten standardmäßig weder Rohbefunde noch Identifikatoren. Ablageorte und verbleibende Grenzen durch Backups, Dateisystem und Betriebssystem werden dokumentiert; sichere physische Löschung wird nicht versprochen.

### E. Öffentliches Projekt und CI

- [ ] **E01 – Lizenz und Herkunft:** Die vorhandene MIT-Lizenz bleibt erhalten. README und gegebenenfalls Drittanbieterhinweise benennen KI-Unterstützung und verwendete Abhängigkeiten. Es wird nicht behauptet, eine MIT-Datei beweise die Urheberschaft an jeder Zeile. Drittanbieter-Lizenzpflichten werden eingehalten.
- [ ] **E02 – Keine privaten Inhalte:** Repository, History, Issues, CI-Logs und Build-Artefakte enthalten ausschließlich öffentliche Konfiguration und ausdrücklich fiktive Testdokumente. Keine echten oder pseudonymisierten Befunde, privaten Hostnamen, Schlüssel, Sperrlisten oder Mappings werden für CI verwendet.
- [ ] **E03 – Kostenbewusste CI:** Workflows verwenden ausschließlich Standard-GitHub-Runner im öffentlichen Repository, keine kostenpflichtigen Larger Runner oder externen Modell-APIs. Build-Artefakte werden höchstens sieben Tage aufbewahrt. Cache-Nutzung ist begrenzt und dokumentiert; Speicherverbrauch wird nicht als garantiert unbegrenzt kostenlos dargestellt.
- [ ] **E04 – CI-Sicherheit:** Workflow-Token erhalten minimale Rechte. Nicht vertrauenswürdige Pull Requests erhalten weder Release-Secrets noch Zugang zum Mac, NAS oder Empfangsserver des Nutzers. Automatisierte Modelltests verwenden ausdrücklich simulierte, entsprechend bezeichnete Antworten; sie ersetzen nicht den separaten echten LM-Studio-Test.
- [ ] **E05 – Dokumentation:** Installation, unterstütztes macOS/Xcode, Start des lokalen Modellservers, lokale Datenspeicherung, Freigabe, Transfer, Fehlerbehandlung und bekannte Grenzen sind aus einem frischen Checkout nachvollziehbar beschrieben. Sicherheitsprobleme können über einen dokumentierten vertraulichen Kanal gemeldet werden.

## 4. Nicht Bestandteil des ersten Zielzustands

- Windows-/Linux-App, App Store, öffentlich gehosteter Verarbeitungsdienst.
- Eigenes Modellhosting, Training oder Auslieferung großer Modellgewichte.
- Garantierte Anonymisierung, juristische Compliance-Zertifizierung oder Medizinprodukt-Zusage.
- Automatische Diagnosen, Therapieempfehlungen oder eine vollständige Gesundheitsakte.
- Automatische Übertragung aller Dokumente ohne Prüfung.
- NAS-Synchronisierung und automatisches Archivieren der Originale.
- Developer-ID-Signierung und Apple-Notarisierung als Pflicht für den ersten Testrelease. Der Release muss seinen tatsächlichen Status offenlegen; eine komfortabel verteilbare signierte Version kann später folgen.

## 5. Pflicht-Testsatz

Alle Dokumente sind künstlich erzeugt und enthalten ausschließlich fiktive Personen und Kennungen. Die erwarteten Identifikatoren, genehmigten Schwärzungen und zu bewahrenden medizinischen Angaben sind maschinenlesbar annotiert. Der Satz enthält mindestens:

1. Mehrseitigen deutschsprachigen Arztbrief mit wiederholtem Namen, Adresse, Geburtsdatum und Versicherungsnummer.
2. Laborblatt mit kleinen Tabellen, Dezimalkomma, negativen Werten, Einheiten und Referenzbereichen.
3. Medikationsplan mit Dosierungen, Datumsangaben und einer klinisch relevanten Verneinung.
4. Reinen Bildscan einschließlich sichtbarer Identifikatoren und manuell zu schwärzendem QR-/Barcode-Bereich.
5. Gedrehte und beschnittene Seiten sowie Zeilenumbrüche innerhalb von Identifikatoren.
6. Gemischtes PDF mit Text- und Scan-Seiten.
7. Dokument mit verstecktem Identifikator in Textschicht, Metadaten, Formular, Annotation und eingebettetem Anhang.
8. Schlechten Scan mit absichtlich unsicherer OCR und einem erkennbaren Zuordnungsproblem.
9. Dokument ohne direkte Identifikatoren, aber mit medizinischen Zahlen und Daten als Fehlalarmkontrolle.
10. Beschädigte und verschlüsselte Eingaben sowie ein Dokument mit eingebetteten manipulativen Anweisungen.

Der Testsatz beweist nur das Verhalten an diesen Fällen. Unbekannte Schreibweisen und Dokumentlayouts können weiterhin übersehene Identifikatoren enthalten. Eine einzelne Recall-Zahl ersetzt keine menschliche Freigabe.

## 6. Verbindlicher End-to-End-Abnahmelauf

1. Aus einem dokumentierten Commit auf einem unterstützten Mac bauen und starten; macOS, Architektur und Xcode festhalten.
2. Den gesamten Pflicht-Testsatz importieren. Warteschlange, Statuswechsel, Abbruch, Wiederholung und Neustart ausführen.
3. Regeln ohne LLM testen. Anschließend mit einem tatsächlich laufenden lokalen LM-Studio-Modell testen und exakte API-Modell-ID sowie relevante Einstellungen dokumentieren. Antworten aus Test-Doubles klar getrennt halten.
4. Fundstellen prüfen, mindestens eine hinzufügen und eine zurücknehmen. Exporte erzeugen. Eine Änderung nach Freigabe muss eine erneute Freigabe verlangen.
5. Original-Hashes vergleichen; Exporte unabhängig rendern, extrahieren und auf Nebeninhalte prüfen. Medizinische Pflichtangaben mit den annotierten Erwartungen vergleichen.
6. Ohne Freigabe einen Upload versuchen: er muss scheitern. Mit Freigabe an ein ausdrücklich autorisiertes synthetisches Testziel übertragen; Identität, Empfänger-Hash, finalen Zielpfad und Status prüfen.
7. Upload unterbrechen, eine Prüfsummenabweichung und fehlende Schreibrechte testen. Wiederholen; keine falschen Erfolgsanzeigen oder beschädigten finalen Dateien zulassen.
8. Netzwerk- und Logprüfung durchführen. Keine Rohdaten außerhalb der erlaubten lokalen Inferenz und des freigegebenen bereinigten Transfers.
9. Alle Kriterien A01–E05 mit Nachweis als bestanden, fehlgeschlagen oder nicht geprüft ausweisen. Fehlgeschlagen oder nicht geprüft bedeutet: **Zielzustand nicht vollständig erreicht**. Änderungen des Umfangs brauchen eine ausdrückliche Entscheidung und eine Aktualisierung dieses Dokuments.

## 7. Form der Abnahmenachweise

Für jede Abnahme entsteht ein Bericht unter `docs/acceptance/` mit:

- geprüftem Commit, Build-/CI-Verweis, Plattform, Werkzeugversionen und verwendeten synthetischen Fixtures;
- Tabelle `Kriterium | Ergebnis | Testbefehl oder Schritte | Nachweis | Einschränkung`;
- Ergebnissen automatisierter Tests, nachvollziehbarer visueller Prüfung und des echten lokalen Modelltests;
- Erkennungsmetriken mit Rohzählungen pro Kategorie, nicht erfundenen oder aus bloßen Annahmen abgeleiteten Quoten;
- dokumentierten offenen Fehlern und einer eindeutigen Gesamtaussage.

Öffentliche Nachweise verwenden nur fiktive Daten und neutrale Testziele. Tests mit privaten Befunden bleiben außerhalb des öffentlichen Repositorys und der CI und benötigen eine gesonderte Freigabe.

## 8. Vor Implementierung festzulegende Einsatzparameter

Diese Angaben sind noch nicht erhoben; sie dürfen nicht als bereits eingerichtet gelten:

- Mac-Chip, RAM, macOS und verfügbare Xcode-Version; daraus abgeleitete Mindestversion.
- Typische Dokumentarten und Scanqualität; Deutsch ist der erste Zielbereich, weitere Sprachen sind nicht zugesichert.
- Tatsächlicher LM-Studio-Endpunkt, verfügbarer Modellname und Parameter.
- Private lokale Ablage, gegebenenfalls NAS-Originalordner und gewünschte Aufbewahrung.
- Autorisierter Empfangsserver, Eingangspfad, Schlüsselverwaltung und technisch durchgesetzte Zugriffsrechte.

Diese Werte gehören in private Konfiguration oder einen ausdrücklich freigegebenen Testaufbau, nicht als persönliche Standardwerte in den öffentlichen Quellcode.
