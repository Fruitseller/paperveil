#!/bin/sh
# PaperVeil – D07 Log-Hygiene-Prüfung (ZIELZUSTAND Abschnitt 6 Schritt 8).
#
# Queries the unified log for the PaperVeil subsystems and pipeline processes
# over the last N minutes and greps for every identifier text AND every
# clinical marker string from Fixtures/synthetic/annotations.json (all "text"
# values, normalised). NONE of them may appear: logs must contain neither raw
# findings nor identifiers (D07).
#
# Note: os.Logger values logged with `privacy: .private` show up as <private>
# in the unified log – that is the expected redaction and is NOT a leak.
#
# Usage:  scripts/log-check.sh [minutes]      (default 30)
# Env:    PAPERVEIL_NETCHECK_FIXTURES  fixture dir (default Fixtures/synthetic)

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="${PAPERVEIL_NETCHECK_FIXTURES:-$ROOT/Fixtures/synthetic}"
ANNOTATIONS="$FIXTURES/annotations.json"
MINUTES="${1:-30}"

if [ ! -f "$ANNOTATIONS" ]; then
    echo "FAIL: annotations not found: $ANNOTATIONS"
    exit 2
fi

echo "== D07 log check: unified log, last ${MINUTES}m =="

# ---------------------------------------------------------------- 1. collect needles

NEEDLES="$(mktemp "${TMPDIR:-/tmp}/paperveil-needles.XXXXXX")"
if command -v jq >/dev/null 2>&1; then
    jq -r '.documents[] | .identifiers[]?.text, .mustPreserve[]?.text' "$ANNOTATIONS" > "$NEEDLES"
else
    # Fallback: every "text" value in the pretty-printed JSON.
    grep -o '"text"[[:space:]]*:[[:space:]]*"[^"]*"' "$ANNOTATIONS" \
        | sed 's/^.*:[[:space:]]*"//; s/"$//' > "$NEEDLES"
fi
# Normalise: JSON escapes -> spaces, collapse whitespace per line, drop empties.
sed -e 's/\\n/ /g' -e 's/\\t/ /g' "$NEEDLES" \
    | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //; s/ $//' | grep -v '^$' | sort -u > "$NEEDLES.n"
mv "$NEEDLES.n" "$NEEDLES"
NEEDLE_COUNT="$(wc -l < "$NEEDLES" | tr -d ' ')"
echo "  needles from annotations.json: $NEEDLE_COUNT (identifier texts + clinical markers)"

# ---------------------------------------------------------------- 2. query the log

LOGOUT="$(mktemp "${TMPDIR:-/tmp}/paperveil-log.XXXXXX")"
if [ -x /usr/bin/log ]; then
    /usr/bin/log show --last "${MINUTES}m" --info --debug --style compact \
        --predicate 'subsystem == "de.paperveil.app"
            OR subsystem == "com.paperveil.PaperVeil"
            OR process == "pv-eval"
            OR process == "netprobe"
            OR process == "PaperVeil"' > "$LOGOUT" 2>/dev/null
else
    echo "FAIL: /usr/bin/log not available"
    exit 2
fi
LOG_LINES="$(grep -v -E '^(Timestamp|Filtering|======|$)' "$LOGOUT" | wc -l | tr -d ' ')"
echo "  log entries in window (subsystems/processes above): $LOG_LINES"
if [ "$LOG_LINES" -eq 0 ]; then
    echo "  (no PaperVeil log entries in the window – nothing to leak; see limitations in docs/acceptance/network-and-logs.md)"
fi
PRIV_COUNT="$(grep -c '<private>' "$LOGOUT" || true)"
echo "  entries containing <private> (os.Logger privacy redaction active): $PRIV_COUNT"

# ---------------------------------------------------------------- 3. search

MATCHES="$(mktemp "${TMPDIR:-/tmp}/paperveil-logmatches.XXXXXX")"
while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    grep -F -- "$needle" "$LOGOUT" | while IFS= read -r line; do
        printf 'LEAK  needle=[%s]  log=%s\n' "$needle" "$line"
    done >> "$MATCHES"
done < "$NEEDLES"

if [ -s "$MATCHES" ]; then
    MATCH_COUNT="$(wc -l < "$MATCHES" | tr -d ' ')"
    echo "  [FAIL] $MATCH_COUNT identifier/clinical strings found in the unified log:"
    sed 's/^/    /' "$MATCHES" | head -30
    echo "RESULT: FAIL ($MATCH_COUNT leaks in the last ${MINUTES}m)"
    exit 1
fi

echo "  [PASS] none of the $NEEDLE_COUNT identifier/clinical strings appears in the unified log"
echo "RESULT: PASS"
exit 0
