# PaperVeil-Empfänger (`paperveil-receive`)

Kleines POSIX-`sh`-Skript für den Server, auf Linux und macOS lauffähig. Es nimmt die
bereinigten Export-PDFs per SSH entgegen und legt sie in einem Eingangsordner ab. Dabei prüft
es die Prüfsumme, schreibt atomar, überschreibt nichts und schreibt nie außerhalb des Ordners.

## Einrichtung

Das Skript läuft in deinem normalen Benutzer, aber **nie als root**. Die Einschränkung hängt
an einem eigenen SSH-Schlüssel nur für PaperVeil, nicht am Benutzer.

1. **Schlüssel auf dem Mac erzeugen** und in PaperVeil unter *Einstellungen → Übertragung* als
   SSH-Schlüsseldatei eintragen:

   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/paperveil -C paperveil
   ```

2. **Auf dem Server** Skript und Eingangsordner anlegen:

   ```sh
   mkdir -p ~/paperveil-inbox && chmod 700 ~/paperveil-inbox
   sudo install -m 755 paperveil-receive /usr/local/bin/paperveil-receive
   ```

3. **In `~/.ssh/authorized_keys` auf dem Server** den öffentlichen Schlüssel
   (`~/.ssh/paperveil.pub`) mit Einschränkung eintragen. Der Pfad zum Eingangsordner muss
   absolut sein:

   ```
   command="/usr/local/bin/paperveil-receive /home/DEIN-NAME/paperveil-inbox",restrict ssh-ed25519 AAAA… paperveil
   ```

   Mit diesem Schlüssel lässt sich nur das Skript ausführen: keine Shell, kein SFTP, keine
   Weiterleitung. Deine übrigen Schlüssel behalten ihren normalen Zugriff.

4. **In PaperVeil** als Host die Tailscale-Adresse des Servers eintragen (`100.x.y.z` oder
   den MagicDNS-Namen), dazu deinen Benutzernamen. Dann *Hostschlüssel abrufen* und den
   Fingerabdruck mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` auf dem Server
   vergleichen.

### Tailscale

- **Tailscale SSH muss auf dem Server aus sein** (`tailscale set --ssh=false`). Ist es an,
  beantwortet Tailscale SSH-Verbindungen auf Port 22 selbst, ohne `authorized_keys` zu
  lesen. Die `command=…,restrict`-Zeile wäre dann wirkungslos. Willst du Tailscale SSH
  behalten, lass PaperVeil einen zweiten `sshd`-Port nutzen, etwa 2222. Auf diesem Port
  gilt `authorized_keys` wieder.
- **Empfehlung:** Eine Regel in den Tailscale-Zugriffsregeln, die dem Mac auf dem Server nur
  den SSH-Port erlaubt.

## Ablauf und Grenzen

PaperVeil ruft `ssh … -- put <Name> <SHA-256> <Größe>` auf und sendet die Datei. Das Skript
nimmt nur Namen der Form `PV-XXXXXXXX-rN.pdf` an und schreibt zuerst in eine temporäre Datei
im Eingangsordner. Danach prüft es Größe und SHA-256 und legt die Datei erst dann unter ihrem
Namen ab. Antwort: `OK <Name> <SHA-256>` oder `ERR <Code> <Meldung>`.

- **Abbruch oder falsche Prüfsumme:** Es entsteht keine Datei.
- **Gleiche Datei erneut:** Das Skript meldet `OK` und legt kein Duplikat an.
- **Gleicher Name, anderer Inhalt:** `ERR EXISTS`, nichts wird überschrieben.
- **Grenze des Schlüssels:** Das Skript schreibt nur in den angegebenen Ordner, die
  Namensprüfung blockiert `..` und `/`. Hätte es einen Fehler, wären die Dateien deines
  Benutzers betroffen. Das ist das Restrisiko dieses einfachen Aufbaus.
- **Kein Ersatz:** Ein Geräteprofil auf dem Mac (z. B. Hermes) ist keine Sicherheitsgrenze.
  Die Grenze setzt der Server durch, über `command=…,restrict`.
- **Was übertragen wird:** nur freigegebene, bereinigte Exporte. Originale, Sperrlisten und
  Fundstellen werden nie übertragen.

## Tests

```sh
sh receiver/test-receiver.sh
```

Die Tests laufen lokal auf macOS und Linux und decken ab:

- erfolgreiche Übertragung und Wiederholung,
- gleicher Name mit anderem Inhalt,
- falsche Prüfsumme und abgebrochene Übertragung,
- ungültige Namen und Ausbruchsversuche,
- fehlende Schreibrechte.

Echte SSH-Verbindungen, Hostschlüssel und Forced Command prüft `Tests/PaperVeilPipelineTests`
gegen einen lokalen `sshd`.
