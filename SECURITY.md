# Sicherheitsrichtlinie

## Schwachstellen melden

Bitte melde Sicherheitsprobleme **nicht** über öffentliche Issues, sondern vertraulich über
GitHubs private Schwachstellenmeldung:
<https://github.com/Fruitseller/paperveil/security/advisories/new>

Lege keine echten Befunde oder personenbezogenen Daten bei. Nutze zur Reproduktion
ausschließlich fiktive Testdokumente (siehe `Fixtures/`).

## Geltungsbereich

Besonders relevant sind:

- Inhalte, die im Export trotz genehmigter Schwärzung lesbar oder extrahierbar bleiben (Text, Metadaten, Formulare, Annotationen, Anhänge).
- Datenabfluss an andere Ziele als den konfigurierten Loopback-Modellserver oder das freigegebene Transferziel.
- Umgehung der Freigabepflicht vor einer Übertragung.
- Schwächen im Empfangsskript (`receiver/`), z. B. Schreibzugriffe außerhalb des Eingangs.

PaperVeil verspricht keine garantierte Anonymisierung. Übersehene Identifikatoren in
unbekannten Layouts sind eine bekannte Grenze. Bitte melde trotzdem reproduzierbare Fälle.
