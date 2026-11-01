# Netzwerk- und Log-Prüfung (D01, D07) – Abnahmebericht

Datum: 2026-11-01 · Branch `t3/a8fad0d1` (Elter-Commit `9712a30`; die hier
beschriebenen Skripte und Tests sind Teil desselben Commits auf diesem Branch).

## Umgebung

| | Wert |
|---|---|
| macOS | 27.2 (Build 26B123) |
| Xcode | 27.2 (Build 27B52), Swift 6.4.2 |
| Architektur | arm64 (Apple Silicon) |
| `sandbox-exec` | `/usr/bin/sandbox-exec` (von Apple als veraltet markiert, auf macOS 27.2 noch voll funktionsfähig) |
| LM Studio | `http://127.0.0.1:1234`, Modell-IDs laut Server: `qwen3.8-27b`, `ornith-1.5-35b-a3b` |
| System-Proxy | keiner konfiguriert (`scutil --proxy`: nur Exceptions-Liste, kein HTTP/SOCKS-Proxy) |
| Fixtures | `Fixtures/synthetic` (vollständig synthetisch, „Mustermann“-Platzhalter, siehe `Fixtures/README.md`) |

## Geprüfte Kriterien

| Kriterium | Ergebnis | Testbefehl oder Schritte | Nachweis | Einschränkung |
|---|---|---|---|---|
| D01 – statische Netzwerkgrenze | **PASS** | `swift test --filter NetworkBoundary` (6 Tests) | Networking-APIs (`URLSession`, `URLRequest`, `NWConnection`, `CFStream`, `Socket`, `URL(string: "http…")`) ausschließlich in `Sources/PaperVeilDetection/LMStudio*.swift`; `Process`/`/usr/bin/ssh*` ausschließlich in `PaperVeilTransfer` und Tooling; keine festkodierten Nicht-Loopback-HTTP-URLs; `LMStudioEndpoint` verwirft `https://api.openai.com`, `http://192.168.1.10:1234`, `http://localhost.evil.com`, `http://127.0.0.1.nip.io` u. a. | Heuristischer Quellscan (Kommentare werden vor dem Matching entfernt; Regex-Literale nicht separat gelext – im aktuellen Code keine Treffer) |
| D01 – offline (Fall a) | **PASS** (Mechanismus + echter Client-Code) | `sh scripts/network-check.sh` → lokale Arbeitslast (SHA-256 einer Fixture) unter `scripts/paperveil-network.sb` (`(deny network*)`); parallel `lsof`-Sampling des gesamten Prozessbaums alle 0,5 s | Arbeitslast erfolgreich, **null** Sockets im Prozessbaum; `curl` an `127.0.0.1:1234` unter dem Profil korrekt verweigert; `LMStudioClient`-Aufruf unter dem Profil schlägt korrekt fehl („Modellserver ist nicht erreichbar“) – kein stiller Fallback | Nachlauf mit echtem `pv-eval report` am 2026-11-01: bestanden (siehe Abschnitt „Nachlauf mit pv-eval“) |
| D01 – Loopback-only mit LLM (Fall b) | **PASS** | gleiche Skript-Ausführung: echter `LMStudioClient`-Aufruf (Release-Objekte von `PaperVeilDetection`) unter dem Profil `(allow network-outbound (remote ip "localhost:1234")) (deny network*)`, Sampling alle 0,5 s | Aufruf erfolgreich (`candidates=3 [address=1 birthDate=1 name=1]`); sämtliche beobachteten Verbindungen ausschließlich `127.0.0.1:… -> 127.0.0.1:1234`; Verbindung zu `192.0.2.1:1234` (RFC-5737-TEST-NET) unter demselben Profil korrekt verweigert | Nachlauf `pv-eval report --llm-model qwen3.8-27b --only F10c`: bestanden (siehe „Nachlauf mit pv-eval“); Sampling-Intervall 0,5 s – Verbindungen, die kürzer bestehen, sind theoretisch als Lücke möglich; `nettop` geprüft, aber `lsof` wegen eindeutiger PID-Zuordnung vorgezogen |
| D01 – Sandbox-Verletzungslog | **nicht aussagekräftig** (siehe Einschränkung) | `log show --last 30m --predicate 'sender == "Sandbox"'`, gefiltert nach Prozessnamen (`netprobe`, `pv-eval`, `curl`) | Keine Netzwerk-Verweigerungen im Unified Log | Auf macOS 27.2 erscheinen Netzwerk-Verweigerungen unter `sandbox-exec` **nicht** im Unified Log (Datei-Verweigerungen erscheinen, Socket-Verweigerungen nicht). Die Verhaltens-Tests (Verbindung scheitert/erfolgt) sind der maßgebliche Nachweis |
| D07 – Logs ohne Identifikatoren | **PASS** | `sh scripts/log-check.sh 30` | Unified Log (Subsysteme `de.paperveil.app`, `com.paperveil.PaperVeil` und Prozesse `pv-eval`/`netprobe`/`PaperVeil`): keines der 79 normalisierten Identifikator- und Klinik-Strings aus `annotations.json` gefunden | Nur Zeilen-basierte Suche (mehrzeilige Leaks über Zeilengrenzen würden nicht matchen); Werte mit `privacy: .private` erscheinen als `<private>` – das ist die erwartete Redaktion, kein Leck |

## Testbefehle (exakt)

```sh
swift test --filter NetworkBoundary                 # statische Prüfung (Swift Testing)
sh scripts/network-check.sh                         # dynamische Prüfung (a) + (b) + Negativkontrollen
sh scripts/log-check.sh 30                          # D07: Unified Log vs. annotations.json
```

Verwendete Sandbox-Profile (exakter Inhalt):

```scheme
;; scripts/paperveil-network.sb  (Fall a: komplett offline)
(version 1)
(allow default)
(deny network*)

;; Fall b: nur Loopback-Port 1234 (vom Skript generiert; macOS 27 akzeptiert
;; im ip-Filter nur "*" oder "localhost" als Hostteil)
(version 1)
(allow default)
(allow network-outbound (remote ip "localhost:1234"))
(deny network*)
```

## Rohauszüge

### `swift test --filter NetworkBoundary`

```
􀟈  Suite NetworkBoundaryTests started.
􀟈  Test networkingAPIsOccurOnlyInLMStudioClient() … passed
􀟈  Test processAndSSHOnlyInTransferAndTooling() … passed
􀟈  Test noHardCodedNonLoopbackURLs() … passed
􀟈  Test endpointRejectsNonLoopbackHosts() … passed
􀟈  Test sourceScanFindsTheExpectedFiles() … passed
􀟈  Test endpointAcceptsOnlyLoopback() … passed
􁛛  Test run with 6 tests in 1 suite passed.
```

### `sh scripts/network-check.sh` (Auszug, Fall a)

```
== case (a): offline run under scripts/paperveil-network.sb ((deny network*)) ==
    LOCAL-OK sha256-prefix=4c46e7f9f5fe
  [PASS] local workload (SHA-256 of a fixture) succeeded with ALL network denied
  [PASS] case (a) local workload connections: no inet sockets observed in the process tree
    LLM-FAIL Der Modellserver ist nicht erreichbar (Netzwerkfehler).
  [PASS] LLM call under (deny network*) correctly FAILED (offline: no silent fallback)
  [PASS] case (a) denied-LLM connections: no inet sockets observed in the process tree
  [PASS] curl to loopback under (deny network*) correctly FAILED (profile blocks network)
```

### `sh scripts/network-check.sh` (Auszug, Fall b)

```
== case (b): run WITH LLM under the loopback-only profile, connections sampled every 0.5s ==
    MODELS qwen3.8-27b,ornith-1.5-35b-a3b
    LLM-OK model=qwen3.8-27b candidates=3 [address=1 birthDate=1 name=1] seconds=109
  [PASS] REAL LMStudioClient call succeeded under the loopback-only profile
    LOOPBACK ESTABLISHED 127.0.0.1:1234
  [PASS] case (b) netprobe connections: only allowed connections observed (mode loopback)
  [PASS] non-loopback connection (192.0.2.1, RFC 5737 TEST-NET) correctly DENIED under the loopback profile
```

(Alle 183 Sampling-Fenster der Phase (b) zeigten ausschließlich
`TCP 127.0.0.1:<ephemer>->127.0.0.1:1234 (ESTABLISHED)`.)

### `sh scripts/log-check.sh 30` (D07)

```
== D07 log check: unified log, last 30m ==
  needles from annotations.json: 79 (identifier texts + clinical markers)
  log entries in window (subsystems/processes above): 25176
  entries containing <private> (os.Logger privacy redaction active): 9556
  [PASS] none of the 79 identifier/clinical strings appears in the unified log
RESULT: PASS
```

### Sandbox-Verletzungslog

```
== sandbox violation log (unified log, last 30m) ==
  no sandbox deny entries for netprobe/pv-eval/curl in the unified log.
  note: on macOS 27.2, network denials under sandbox-exec were NOT observed in the
  unified log at all (file denials appear, socket denials do not). This check is
  informational; the behavioural evidence above is authoritative.
```

## Was genau geprüft wurde

1. **Statisch** (`Tests/PaperVeilPipelineTests/NetworkBoundaryTests.swift`): Scan
   aller Swift-Dateien unter `Sources/` (Repo-Wurzel via `#filePath`), nach Entfernen
   von Kommentaren (Dokumentationskommentare sind damit ausgenommen, String-Literale
   bleiben geprüft):
   - `URLSession`, `URLRequest`, `NWConnection`, `CFStream`, `Socket`,
     `URL(string: "http…"` nur in `Sources/PaperVeilDetection/LMStudio*.swift`;
   - `Process` (Wortgrenze, d. h. `ProcessingWarning`/`ProcessOutput` treffen nicht)
     und `/usr/bin/ssh*`, `NSTask`, `posix_spawn` nur in `Sources/PaperVeilTransfer/`,
     `Sources/pv-fixtures/`, `Sources/pv-eval/`;
   - keine festkodierten `http(s)://`-Literale mit Nicht-Loopback-Host (erlaubt:
     `127.0.0.1`, `localhost`, `[::1]`; interpolierte Hosts werden abgelehnt);
   - `LMStudioEndpoint` verwirft Cloud-APIs, LAN-Adressen und DNS-Tricks
     (`localhost.evil.com`, `127.0.0.1.nip.io`, `sub.localhost`, `0.0.0.0`,
     Credentials, Nicht-http-Schemas).
2. **Dynamisch** (`scripts/network-check.sh`):
   - Baut `pv-eval` (Release) **außerhalb** der Sandbox (SwiftPM verschachtet
     selbst `sandbox-exec` für die Manifest-Kompilierung; verschachtelte
     Sandbox-Anwendung wird vom Kernel verweigert – daher Build außen,
     Ausführung unter Profil).
   - **pv-eval-Erkennung:** Hat `pv-eval` noch keinen `report`-Subcommand
     (im Arbeitszweig: Stub `print("pv-eval")`), fällt das Skript auf einen zur
     Laufzeit kompilierten **netprobe** zurück, der gegen die echten
     Release-Objekte von `PaperVeilDetection` gelinkt ist und den produktiven
     `LMStudioClient` (`listModels` + `findCandidates`) ausführt – die Sandbox
     wird also vom echten Client-Code getestet, nicht nur von `curl`.
   - **Fall (a)**: lokale Arbeitslast unter `(deny network*)` muss gelingen und
     darf **keinen** Socket erzeugen; LLM-Aufruf und `curl` unter demselben
     Profil müssen scheitern (kein stiller Cloud-Fallback).
   - **Fall (b)**: echter `LMStudioClient`-Aufruf unter
     `(allow network-outbound (remote ip "localhost:1234")) (deny network*)`;
     parallel wird alle 0,5 s mit `lsof -i -n -P` jeder Inet-Socket des
     **gesamten Prozessbaums** (rekursive `pgrep -P`-Abstammung) mitgeschrieben;
     jede nicht-Loopback-Remote-Adresse (IPv4 und IPv6) lässt den Lauf scheitern.
     Negativkontrolle: Verbindung nach `192.0.2.1:1234` (TEST-NET-1, RFC 5737 –
     die Sandbox verweigert lokal, bevor ein Paket den Rechner verlässt) muss
     scheitern.
   - **Sandbox-Log**: Abfrage des Unified Log nach `Sandbox`-Verweigerungen,
     gefiltert nach den beteiligten Prozessnamen.
3. **D07** (`scripts/log-check.sh`): Unified Log der letzten N Minuten
   (Subsysteme `de.paperveil.app` **und** `com.paperveil.PaperVeil` – beide sind
   im Code in Gebrauch – sowie Prozesse `pv-eval`, `netprobe`, `PaperVeil`), gesucht
   wird mit **jedem** normalisierten `text`-Wert aus
   `Fixtures/synthetic/annotations.json` (alle Identifikator- und
   Klinik-/mustPreserve-Strings; 79 eindeutige Nadeln). Fund = FAIL.

## Ehrliche Einschränkungen und offene Punkte

1. **pv-eval-Stub:** `pv-eval` existiert im Arbeitszweig noch als Stub. Die
   dynamischen Läufe (a)/(b) wurden daher mit dem **echten
   `PaperVeilDetection.LMStudioClient`** (netprobe, gegen die Release-Objekte
   gelinkt) und `curl` als Negativkontrolle nachgewiesen. **Offen:** der konkrete
   `pv-eval report`-Offline-Lauf und der `pv-eval report --llm-model qwen3.8-27b`
   Lauf (inkl. `--only F10c`, sofern unterstützt) sind nachzuliefern, sobald
   `pv-eval` den `report`-Subcommand implementiert hat – das Skript erkennt das
   automatisch. Bis dahin ist D01 für die **Pipeline-Ende-zu-Ende-Ebene**
   „bestanden mit dokumentierter Lücke“, nicht vollständig abgenommen.
2. **sandbox-exec ist veraltet** (Apple). Auf macOS 27.2 funktioniert es
   einwandfrei; fällt es in einer zukünftigen Version weg, schaltet das Skript
   auf rein Sampling-Beobachtung um und weist dies aus – **Aussagekraft wäre dann
   geringer** (keine Durchsetzung mehr, nur Beobachtung).
3. **Netzwerk-Verweigerungen erscheinen nicht im Unified Log** (macOS 27.2):
   Datei-Verweigerungen ja, Socket-Verweigerungen nein. Der Log-Check ist damit
   nur informativ; die Verhaltensnachweise (Verbindung verweigert/erlaubt,
   Null-Sockets offline) sind maßgeblich.
4. **Sampling-Intervall 0,5 s:** Verbindungen, die kürzer als das Intervall
   bestehen, könnten einzeln verpasst werden. Im LLM-Lauf (109–220 s) war die
   Verbindung durchgehend etabliert (183/183 Fenster). `nettop -P -L 0 -J …`
   wurde erwogen, aber `lsof` gewählt, weil es ein eindeutiges PID-Matching im
   Prozessbaum erlaubt.
5. **GUI-App nicht abgedeckt:** Der Test deckt den Erkennungs-Client
   (`PaperVeilDetection`) und den Netzwerk-Mechanismus ab – nicht die laufende
   `PaperVeil.app`-GUI (Export, Transfer-UI). Der Transfer (`/usr/bin/ssh`) war
   hier nicht Teil der LLM-Läufe.
6. **DNS/`localhost`:** Der produktive Endpunkt ist `127.0.0.1:1234` – keine
   DNS-Auflösung nötig. Der Profil-Filter `"localhost:1234"` deckt die
   Loopback-Verbindung ab; eine Weiterleitung per `/etc/hosts` auf Nicht-Loopback
   würde die Sandbox dennoch blockieren (`(deny network*)` greift für jede
   andere Adresse). LM Studio lauscht nur auf `127.0.0.1` (`::1` verweigert), der
   IPv6-Loopback-Pfad wurde deshalb nicht positiv getestet.
7. **Kein System-Proxy konfiguriert** während des Tests. Mit konfiguriertem
   HTTP-Proxy wäre das Verhalten von `URLSession` für Loopback-Adressen
   separat zu prüfen.
8. **os.Logger-Redaktion:** Werte mit `privacy: .private` erscheinen als
   `<private>` – das ist beabsichtigt und kein Hinweis auf versteckte Leaks; die
   geprüften PaperVeil-Log-Meldungen sind ohnehin neutral (Dokument-ID, Phase,
   Fehlercode).
9. **SwiftPM nicht unter sandbox-exec ausführbar** (verschachtelte Sandbox wird
   verweigert): Binaries werden deshalb außerhalb gebaut und nur die Ausführung
   unter dem Profil getestet – die getestete Binärdatei ist die des Builds, kein
   Zwischenschritt läuft ungesandboxt mit Netzwerkzugriff.

## Gesamtaussage

- **D01 (statisch): bestanden** – Netzwerk-APIs, Prozess-APIs und URL-Literale
  sind auf die zugelassenen Module begrenzt; `LMStudioEndpoint` verhindert
  strukturell jeden Nicht-Loopback-Zielhost.
- **D01 (dynamisch): bestanden mit dokumentierter Lücke** – Offline-Betrieb
  (lokale Arbeitslast, null Sockets, korrekt scheiternder LLM-Aufruf) und
  Loopback-only-Inferenz (nur `127.0.0.1:1234`, Nicht-Loopback verweigert) sind
  nachgewiesen; ausständig ist der konkrete `pv-eval report`-Lauf, sobald das
  Tool den Subcommand implementiert hat.
- **D07 (Log-Hygiene): bestanden** – keines der 79 Identifikator-/Klinik-Strings
  aus `annotations.json` im Unified Log des Prüffensters.


## Nachlauf mit pv-eval (2026-11-01)

Nach der Integration von `pv-eval` wurde `sh scripts/network-check.sh` erneut ausgeführt
(macOS 27.2, Xcode 27.2, M4 Max, LM Studio `qwen3.8-27b`):

```
  [PASS] swift build -c release --product pv-eval
  [PASS] model id 'qwen3.8-27b' is offered by the server
  [PASS] pv-eval report (no LLM) succeeded with ALL network denied
  [PASS] case (a) connections: no inet sockets observed in the process tree
  [PASS] pv-eval report WITH LLM succeeded under the loopback-only profile
  [PASS] case (b) pv-eval connections: only allowed connections observed (mode loopback)
  [PASS] non-loopback connection (192.0.2.1, RFC 5737 TEST-NET) correctly DENIED under the loopback profile
PASS: 7   FAIL: 0   SKIP: 0
```

Damit ist der offene Punkt aus „Offene Punkte“ erledigt: Der vollständige Qualitätslauf läuft
ohne jede Netzwerkverbindung. Der LLM-Lauf (F10c, manipulative Anweisungen) baut ausschließlich
Verbindungen zu `127.0.0.1:1234` auf.
