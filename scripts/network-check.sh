#!/bin/sh
# PaperVeil – kontrollierter Netzwerk-Grenztest (D01, ZIELZUSTAND Abschnitt 6 Schritt 8).
#
# Case (a)  WITHOUT LLM: a PaperVeil run under scripts/paperveil-network.sb,
#          which denies ALL networking ((deny network*)). Local processing must
#          still succeed → offline operation is proven.
# Case (b)  WITH LLM: the same run under a loopback-only profile that allows
#          ONLY (remote ip "localhost:1234") outbound. All connections of the
#          process tree are sampled every 0.5 s (lsof -i -n -P, nettop exists
#          but has no scriptable one-shot mode with per-pid attribution); the
#          run FAILS if any remote address is not 127.0.0.1/::1.
# Log check: sandbox violations are queried from the unified log
#          (log show --predicate 'sender == "Sandbox"', filtered by process
#          name). NOTE: on macOS 27.2, network denials under sandbox-exec were
#          NOT observed in the unified log (only file-read denials appear), so
#          this check is informational; the behavioural checks above are the
#          authoritative evidence.
#
# If the pv-eval CLI is still the parallel-work stub (no "report" subcommand),
# this script falls back to a compiled netprobe that calls the REAL
# PaperVeilDetection.LMStudioClient (linked against the release objects) under
# the same sandbox profiles, and documents the pending pv-eval run. Either way
# every case prints PASS/FAIL and the script exits non-zero on any FAIL.
#
# Usage:  scripts/network-check.sh
# Env:    PAPERVEIL_NETCHECK_MODEL   LM Studio model id (default qwen3.8-27b)
#         PAPERVEIL_NETCHECK_FIXTURES  fixture dir (default Fixtures/synthetic)
#         PAPERVEIL_NETCHECK_LOG_MINUTES  unified-log window (default 30)
# A local LM Studio server on http://127.0.0.1:1234 is required for case (b).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OFFLINE_PROFILE="$ROOT/scripts/paperveil-network.sb"
MODEL="${PAPERVEIL_NETCHECK_MODEL:-qwen3.8-27b}"
FIXTURES="${PAPERVEIL_NETCHECK_FIXTURES:-$ROOT/Fixtures/synthetic}"
LOG_MINUTES="${PAPERVEIL_NETCHECK_LOG_MINUTES:-30}"
LSOF=/usr/sbin/lsof
SAMPLE_INTERVAL=0.5

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  [SKIP] %s\n' "$1"; SKIP=$((SKIP + 1)); }
note() { printf '  note: %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/paperveil-netcheck.XXXXXX")"
echo "workdir: $WORK"

# ---------------------------------------------------------------- helpers

# pid + all descendants of $1 (space-separated)
tree_pids() {
    _list="$1"; _front="$1"
    while [ -n "$_front" ]; do
        _children=""
        for _p in $_front; do
            _c="$(pgrep -P "$_p" 2>/dev/null)"
            [ -n "$_c" ] && _children="$_children $_c"
        done
        [ -z "$_children" ] && break
        _list="$_list $_children"
        _front="$_children"
    done
    echo "$_list"
}

# Sample all inet sockets of the tree below pid $1 into $2 until $1 is gone.
sample_connections() {
    _rootpid="$1"; _out="$2"
    while kill -0 "$_rootpid" 2>/dev/null; do
        _pids="$(tree_pids "$_rootpid")"
        "$LSOF" -i -n -P 2>/dev/null | awk -v pids="$_pids" '
            BEGIN { n = split(pids, a, " "); for (i = 1; i <= n; i++) P[a[i]] = 1 }
            $2 in P { print }
        ' >> "$_out"
        sleep "$SAMPLE_INTERVAL"
    done
}

# Analyse captured lsof lines.
#   mode "offline": ANY established connection or listener is a violation.
#   mode "loopback": any ESTABLISHED remote that is not 127.0.0.1/::1/localhost
#                   is a violation (LISTEN is reported as a note).
analyze_samples() { # $1 samples file, $2 mode, $3 label
    [ -s "$1" ] || { ok "$3: no inet sockets observed in the process tree"; return 0; }
    _viol="$(awk -v MODE="$2" '
        # lsof -i -n -P line: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE PROTO ADDR (STATE)
        $8 != "TCP" && $8 != "UDP" { next }
        {
            state = ""; if ($10 ~ /^\(/) state = substr($10, 2, length($10) - 2)
            if ($9 ~ /->/) {
                idx = index($9, "->")
                remote = substr($9, idx + 2)
                conns[state " " remote]++
            } else {
                listens[$9 " " state]++
            }
        }
        END {
            v = 0
            for (k in conns) {
                split(k, a, " "); remote = a[2]
                host = remote
                if (substr(host, 1, 1) == "[") {
                    i = index(host, "]"); host = substr(host, 2, i - 2)
                } else {
                    i = index(host, ":"); if (i > 0) host = substr(host, 1, i - 1)
                }
                if (MODE == "offline") { printf("VIOLATION-CONNECT %s\n", k); v++ }
                else if (host != "127.0.0.1" && host != "::1" && host != "localhost") {
                    printf("VIOLATION-REMOTE host=%s remote=%s\n", host, remote); v++
                } else { printf("LOOPBACK %s\n", k) }
            }
            for (k in listens) {
                if (MODE == "offline") { printf("VIOLATION-LISTEN %s\n", k); v++ }
                else printf("NOTE-LISTEN %s\n", k)
            }
            exit(v > 0 ? 1 : 0)
        }
    ' "$1")"
    _rc=$?
    printf '%s\n' "$_viol" | sed 's/^/    /'
    if [ "$_rc" -eq 0 ]; then
        ok "$3: only allowed connections observed (mode $2)"
    else
        bad "$3: disallowed network activity (mode $2)"
    fi
    return "$_rc"
}

# Run a command under a sandbox profile, sampling its connections.
# $1 profile, $2 samples-out, $3.. command
run_sandboxed() {
    _profile="$1"; _samples="$2"; shift 2
    : > "$_samples"
    "$SANDBOX_EXEC" -f "$_profile" "$@" &
    _pid=$!
    sample_connections "$_pid" "$_samples"
    wait "$_pid"
}

# ---------------------------------------------------------------- 0. environment

echo
echo "== environment =="
sw_vers | sed 's/^/  /'
xcodebuild -version | sed 's/^/  /'
echo "  model server: http://127.0.0.1:1234 (model id: $MODEL)"
echo "  fixtures: $FIXTURES"

SANDBOX_EXEC="$(command -v sandbox-exec 2>/dev/null || true)"
if [ -z "$SANDBOX_EXEC" ]; then
    note "sandbox-exec not present – falling back to connection sampling only; the offline/loopback cases are then NOT enforced, only observed."
    SANDBOX_AVAILABLE=0
else
    echo "  sandbox-exec: $SANDBOX_EXEC (deprecated by Apple, still functional)"
    SANDBOX_AVAILABLE=1
fi
if [ ! -f "$OFFLINE_PROFILE" ]; then
    bad "offline profile missing: $OFFLINE_PROFILE"
fi

# The loopback-only profile is generated here because it embeds the LM Studio
# port. On macOS 27 the SBPL ip filter accepts only '*' or 'localhost' hosts.
LOOPBACK_PROFILE="$WORK/paperveil-network-loopback.sb"
cat > "$LOOPBACK_PROFILE" <<'EOF'
(version 1)
(allow default)
(allow network-outbound (remote ip "localhost:1234"))
(deny network*)
EOF
echo "  loopback profile: $LOOPBACK_PROFILE"
sed 's/^/    /' "$LOOPBACK_PROFILE" | head -6

# ---------------------------------------------------------------- 1. build pv-eval

echo
echo "== build (outside the sandbox; SwiftPM nests its own sandbox-exec and cannot run inside one) =="
if swift build -c release --product pv-eval >"$WORK/build.log" 2>&1; then
    ok "swift build -c release --product pv-eval"
else
    bad "pv-eval release build failed (see $WORK/build.log)"
fi
BIN_DIR="$(swift build -c release --show-bin-path)"
PV_EVAL="$BIN_DIR/pv-eval"

# ---------------------------------------------------------------- 2. LM Studio reachable?

echo
echo "== LM Studio reachability (informational, direct call) =="
if MODELS_JSON="$(curl -s --noproxy '*' --max-time 5 http://127.0.0.1:1234/v1/models)"; then
    echo "  $MODELS_JSON" | head -c 400
    if printf '%s' "$MODELS_JSON" | grep -q "\"$MODEL\""; then
        ok "model id '$MODEL' is offered by the server"
        LMSTUDIO=1
    else
        bad "model id '$MODEL' NOT offered by the server; set PAPERVEIL_NETCHECK_MODEL"
        LMSTUDIO=0
    fi
else
    bad "no LM Studio server on http://127.0.0.1:1234 (case (b) cannot run)"
    LMSTUDIO=0
fi

# ---------------------------------------------------------------- 3. pv-eval functional?

PV_HELP="$("$PV_EVAL" --help 2>&1 || true)"
case "$PV_HELP" in
    *report*) PV_FUNCTIONAL=1 ;;
    *) PV_FUNCTIONAL=0 ;;
esac
if [ "$PV_FUNCTIONAL" -eq 1 ]; then
    echo
    echo "== pv-eval CLI detected – real report runs =="
    case "$PV_HELP" in
        *--only*) PV_ONLY=1 ;;
        *) PV_ONLY=0 ;;
    esac
else
    echo
    echo "== pv-eval is still the stub (no 'report' subcommand): $PV_HELP"
    note "pv-eval is being written in parallel; this run verifies the sandbox mechanism with a compiled netprobe that calls the REAL PaperVeilDetection.LMStudioClient. Re-run this script once pv-eval's 'report' exists."
    PV_ONLY=0
fi

# ---------------------------------------------------------------- 4. netprobe (real client)

if [ "$PV_FUNCTIONAL" -eq 0 ]; then
    echo
    echo "== netprobe: compiling a probe against the real PaperVeilDetection release objects =="
    REL="$ROOT/.build/release"
    cat > "$WORK/netprobe.swift" <<'SWIFTEOF'
// Written by scripts/network-check.sh. Tiny D01 probe that runs the REAL
// PaperVeil LMStudioClient against the local LM Studio server, so the sandbox
// boundary is exercised by the production client code, not by curl alone.
import Foundation
import PaperVeilCore
import PaperVeilDetection

@main
struct NetProbe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else { print("usage: netprobe local <file> | llm"); exit(2) }
        let model = ProcessInfo.processInfo.environment["PAPERVEIL_NETCHECK_MODEL"] ?? "qwen3.8-27b"
        switch args[1] {
        case "local":
            // Purely local workload (hash a fixture) – no networking APIs used.
            let path = args.count > 2 ? args[2] : "Fixtures/synthetic/F09-ohne-identifikatoren.pdf"
            do {
                let hex = try SHA256Hex.of(fileAt: URL(fileURLWithPath: path))
                print("LOCAL-OK sha256-prefix=\(hex.prefix(12))")
            } catch {
                print("LOCAL-FAIL \(error)")
                exit(1)
            }
        case "llm":
            // The production code path: listModels + findCandidates over the
            // loopback endpoint, exactly like the app does.
            do {
                let client = LMStudioClient(endpoint: .localDefault)
                let models = try await client.listModels()
                print("MODELS \(models.joined(separator: ","))")
                let page = PageText(pageIndex: 0, words: [
                    TextWord(text: "Erika", rect: PageRect(x: 0, y: 0, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 0),
                    TextWord(text: "Mustermann,", rect: PageRect(x: 12, y: 0, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 0),
                    TextWord(text: "geb.", rect: PageRect(x: 24, y: 0, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 0),
                    TextWord(text: "12.03.1961,", rect: PageRect(x: 30, y: 0, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 0),
                    TextWord(text: "Musterstraße", rect: PageRect(x: 0, y: 14, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 1),
                    TextWord(text: "5,", rect: PageRect(x: 12, y: 14, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 1),
                    TextWord(text: "12345", rect: PageRect(x: 16, y: 14, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 1),
                    TextWord(text: "Musterstadt", rect: PageRect(x: 22, y: 14, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 1),
                    TextWord(text: "Kalium", rect: PageRect(x: 0, y: 28, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 2),
                    TextWord(text: "4,2", rect: PageRect(x: 12, y: 28, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 2),
                    TextWord(text: "mmol/l", rect: PageRect(x: 16, y: 28, width: 10, height: 10), source: .pdfText, confidence: 1.0, line: 2),
                ])
                let start = Date()
                let candidates = try await client.findCandidates(page: page, model: model, timeout: .seconds(240))
                // Categories only: never print quote text or document content (D07).
                let byCategory = Dictionary(grouping: candidates, by: \.category)
                    .map { "\($0.key.rawValue)=\($0.value.count)" }
                    .sorted()
                    .joined(separator: " ")
                let seconds = Int(Date().timeIntervalSince(start))
                print("LLM-OK model=\(model) candidates=\(candidates.count) [\(byCategory)] seconds=\(seconds)")
            } catch {
                print("LLM-FAIL \(error)")
                exit(1)
            }
        default:
            print("usage: netprobe local <file> | llm")
            exit(2)
        }
    }
}
SWIFTEOF
    if swiftc -O -parse-as-library "$WORK/netprobe.swift" -I "$REL" -o "$WORK/netprobe" \
        "$REL/PaperVeilDetection.o" "$REL/PaperVeilCore.o" 2>"$WORK/netprobe-build.log"; then
        ok "netprobe compiled against real release objects ($REL/PaperVeilDetection.o)"
    else
        bad "netprobe compile failed (see $WORK/netprobe-build.log)"
        cat "$WORK/netprobe-build.log" | sed 's/^/    /' | head -20
    fi
fi

# ---------------------------------------------------------------- 5. case (a): offline

echo
echo "== case (a): offline run under scripts/paperveil-network.sb ((deny network*)) =="
if [ "$SANDBOX_AVAILABLE" -eq 0 ]; then
    skip "sandbox-exec missing – offline enforcement not possible"
elif [ "$PV_FUNCTIONAL" -eq 1 ]; then
    echo "  running: sandbox-exec -f scripts/paperveil-network.sb pv-eval report --fixtures ... --out $WORK/offline-report.md"
    run_sandboxed "$OFFLINE_PROFILE" "$WORK/a-pv-eval.samples" \
        "$PV_EVAL" report --fixtures "$FIXTURES" --out "$WORK/offline-report.md" >"$WORK/a-pv-eval.log" 2>&1
    rc=$?
    sed 's/^/    /' "$WORK/a-pv-eval.log" | tail -8
    if [ "$rc" -eq 0 ] && [ -s "$WORK/offline-report.md" ]; then
        ok "pv-eval report (no LLM) succeeded with ALL network denied"
    else
        bad "pv-eval report (no LLM) failed under (deny network*) (rc=$rc)"
    fi
    analyze_samples "$WORK/a-pv-eval.samples" offline "case (a) connections"
else
    run_sandboxed "$OFFLINE_PROFILE" "$WORK/a-local.samples" \
        "$WORK/netprobe" local "$FIXTURES/F09-ohne-identifikatoren.pdf" >"$WORK/a-local.log" 2>&1
    rc=$?
    sed 's/^/    /' "$WORK/a-local.log"
    [ "$rc" -eq 0 ] && ok "local workload (SHA-256 of a fixture) succeeded with ALL network denied" \
                    || bad "local workload failed under (deny network*) (rc=$rc)"
    analyze_samples "$WORK/a-local.samples" offline "case (a) local workload connections"

    run_sandboxed "$OFFLINE_PROFILE" "$WORK/a-llm-denied.samples" \
        "$WORK/netprobe" llm >"$WORK/a-llm-denied.log" 2>&1
    rc=$?
    sed 's/^/    /' "$WORK/a-llm-denied.log" | head -4
    [ "$rc" -ne 0 ] && ok "LLM call under (deny network*) correctly FAILED (offline: no silent fallback)" \
                    || bad "LLM call unexpectedly SUCCEEDED under (deny network*)"
    analyze_samples "$WORK/a-llm-denied.samples" offline "case (a) denied-LLM connections"

    run_sandboxed "$OFFLINE_PROFILE" "$WORK/a-curl-denied.samples" \
        /usr/bin/curl -s --noproxy '*' --max-time 5 http://127.0.0.1:1234/v1/models >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] && ok "curl to loopback under (deny network*) correctly FAILED (profile blocks network)" \
                    || bad "curl to loopback unexpectedly SUCCEEDED under (deny network*)"
    note "pv-eval's own offline report run is still pending (stub); re-run when pv-eval 'report' exists."
fi

# ---------------------------------------------------------------- 6. case (b): loopback-only + LLM

echo
echo "== case (b): run WITH LLM under the loopback-only profile, connections sampled every ${SAMPLE_INTERVAL}s =="
if [ "$SANDBOX_AVAILABLE" -eq 0 ]; then
    skip "sandbox-exec missing – loopback enforcement not possible"
elif [ "$LMSTUDIO" -eq 0 ]; then
    skip "no LM Studio server – case (b) not run"
else
    echo "  this call may take a few minutes (local model); sampling runs in parallel …"
    if [ "$PV_FUNCTIONAL" -eq 1 ]; then
        ONLY_ARGS=""
        [ "$PV_ONLY" -eq 1 ] && ONLY_ARGS="--only F10c"
        echo "  running: sandbox-exec -f paperveil-network-loopback.sb pv-eval report --llm-model $MODEL $ONLY_ARGS"
        run_sandboxed "$LOOPBACK_PROFILE" "$WORK/b-pv-eval.samples" \
            "$PV_EVAL" report --fixtures "$FIXTURES" --llm-model "$MODEL" $ONLY_ARGS \
            --out "$WORK/llm-report.md" >"$WORK/b-pv-eval.log" 2>&1
        rc=$?
        sed 's/^/    /' "$WORK/b-pv-eval.log" | tail -8
        if [ "$rc" -eq 0 ] && [ -s "$WORK/llm-report.md" ]; then
            ok "pv-eval report WITH LLM succeeded under the loopback-only profile"
        else
            bad "pv-eval report WITH LLM failed under the loopback-only profile (rc=$rc)"
        fi
        B_SAMPLES="$WORK/b-pv-eval.samples"
        B_LABEL="case (b) pv-eval connections"
    else
        run_sandboxed "$LOOPBACK_PROFILE" "$WORK/b-netprobe.samples" \
            "$WORK/netprobe" llm >"$WORK/b-netprobe.log" 2>&1
        rc=$?
        sed 's/^/    /' "$WORK/b-netprobe.log" | head -6
        if [ "$rc" -eq 0 ]; then
            ok "REAL LMStudioClient call succeeded under the loopback-only profile"
        else
            bad "netprobe LLM call failed under the loopback-only profile (rc=$rc)"
        fi
        B_SAMPLES="$WORK/b-netprobe.samples"
        B_LABEL="case (b) netprobe connections"
    fi
    analyze_samples "$B_SAMPLES" loopback "$B_LABEL"

    # negative control: non-loopback is denied under the SAME profile
    run_sandboxed "$LOOPBACK_PROFILE" "$WORK/b-testnet.samples" \
        /usr/bin/curl -s --noproxy '*' --max-time 4 http://192.0.2.1:1234/ >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] && ok "non-loopback connection (192.0.2.1, RFC 5737 TEST-NET) correctly DENIED under the loopback profile" \
                    || bad "non-loopback connection unexpectedly SUCCEEDED under the loopback profile"
fi

# ---------------------------------------------------------------- 7. sandbox violation log

echo
echo "== sandbox violation log (unified log, last ${LOG_MINUTES}m) =="
if [ -x /usr/bin/log ]; then
    /usr/bin/log show --last "${LOG_MINUTES}m" --predicate 'sender == "Sandbox"' --info --style compact \
        2>/dev/null | grep -E 'deny|reject' | grep -E 'netprobe|pv-eval|curl|sandbox-exec' > "$WORK/sandbox-log.txt" || true
    if [ -s "$WORK/sandbox-log.txt" ]; then
        echo "  denials involving our processes:"
        sed 's/^/    /' "$WORK/sandbox-log.txt" | head -20
        note "denials listed above are expected for the negative controls (curl under deny-all / TEST-NET); they confirm the sandbox catches attempts. If they concern a case (a)/(b) workload run itself, treat that as a D01 violation."
    else
        echo "  no sandbox deny entries for netprobe/pv-eval/curl in the unified log."
        note "on macOS 27.2, network denials under sandbox-exec were NOT observed in the unified log at all (file denials appear, socket denials do not). This check is informational; the behavioural evidence above is authoritative."
    fi
else
    skip "/usr/bin/log not available"
fi

# ---------------------------------------------------------------- 8. summary

echo
echo "=============================== SUMMARY ==============================="
echo "sandbox-exec: $SANDBOX_AVAILABLE  |  pv-eval functional: $PV_FUNCTIONAL  |  LM Studio: $LMSTUDIO"
echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
echo "artifacts: $WORK (samples, logs, reports)"
if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
exit 0
