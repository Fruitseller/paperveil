#!/bin/sh
#
# Portable tests for receiver/paperveil-receive (macOS and Ubuntu).
# Runs the script directly with SSH_ORIGINAL_COMMAND set, simulating sshd.
#
# Run:  sh receiver/test-receiver.sh

set -u
cd "$(dirname "$0")" || exit 1
script="$(pwd)/paperveil-receive"

passed=0
failed=0
note() { printf 'ok   %s\n' "$1"; passed=$((passed + 1)); }
bail() { printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); }

work=$(mktemp -d) || exit 1
inbox="$work/inbox"
fixtures="$work/fixtures"
mkdir -p "$inbox" "$fixtures" || exit 1

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f1
    else
        shasum -a 256 "$1" | cut -d ' ' -f1
    fi
}

# put <inbox> <name> <sha256> <size> <input-file>
put() {
    SSH_ORIGINAL_COMMAND="put $2 $3 $4" "$script" "$1" < "$5"
}

# expect_ok <desc> <expected-line> <out> <status>
expect_ok() {
    if [ "$4" -eq 0 ] && [ "$3" = "$2" ]; then note "$1"; else
        bail "$1: expected [$2] (status 0), got [$3] (status $4)"
    fi
}

# expect_err <desc> <expected-code> <out> <status>
expect_err() {
    if [ "$4" -eq 0 ]; then
        bail "$1: expected failure, got [$3]"
        return
    fi
    case $3 in
    "ERR $2"*) note "$1 -> $3" ;;
    *) bail "$1: expected ERR $2..., got [$3] (status $4)" ;;
    esac
}

expect_no_file() { # expect_no_file <desc> <path>
    if [ -e "$2" ] || [ -L "$2" ]; then bail "$1: file exists: $2"; else note "$1"; fi
}

incoming_empty() { # incoming_empty <desc> <inbox>
    n=$(find "$2/.incoming" -type f 2>/dev/null | wc -l | tr -d ' ')
    n=${n:-0}
    if [ "$n" -eq 0 ] 2>/dev/null; then note "$1"; else bail "$1: temp files left behind"; fi
}

printf 'hello paper veil\n' > "$fixtures/a.pdf"
a_sha=$(sha "$fixtures/a.pdf")
a_size=$(wc -c < "$fixtures/a.pdf" | tr -d ' ')
printf 'different content\n' > "$fixtures/b.pdf"
b_sha=$(sha "$fixtures/b.pdf")
b_size=$(wc -c < "$fixtures/b.pdf" | tr -d ' ')

# --- 1. successful put --------------------------------------------------------
out=$(put "$inbox" PV-1234ABCD-r1.pdf "$a_sha" "$a_size" "$fixtures/a.pdf"); st=$?
expect_ok "successful put" "OK PV-1234ABCD-r1.pdf $a_sha" "$out" "$st"
cmp -s "$fixtures/a.pdf" "$inbox/PV-1234ABCD-r1.pdf" && note "final file content matches" || bail "final file content differs"
incoming_empty "no temp files left after success" "$inbox"

# --- 2. idempotent retry ------------------------------------------------------
out=$(put "$inbox" PV-1234ABCD-r1.pdf "$a_sha" "$a_size" "$fixtures/a.pdf"); st=$?
expect_ok "idempotent retry" "OK PV-1234ABCD-r1.pdf $a_sha" "$out" "$st"
n=$(find "$inbox" -maxdepth 1 -name 'PV-*.pdf' | wc -l | tr -d ' ')
[ "$n" -eq 1 ] && note "still exactly one final file" || bail "expected 1 final file, found $n"

# --- 3. different content, same name: rejected, never overwritten ------------
out=$(put "$inbox" PV-1234ABCD-r1.pdf "$b_sha" "$b_size" "$fixtures/b.pdf"); st=$?
expect_err "different content same name rejected" EXISTS "$out" "$st"
cmp -s "$fixtures/a.pdf" "$inbox/PV-1234ABCD-r1.pdf" && note "existing file untouched" || bail "existing file was overwritten"
incoming_empty "no temp files left after rejection" "$inbox"

# --- 4. checksum mismatch ----------------------------------------------------
out=$(put "$inbox" PV-99999999-r1.pdf "$b_sha" "$a_size" "$fixtures/a.pdf"); st=$?
expect_err "checksum mismatch rejected" CHECKSUM "$out" "$st"
expect_no_file "no final file after checksum mismatch" "$inbox/PV-99999999-r1.pdf"

# --- 5. truncated input (interrupted upload) ---------------------------------
out=$(put "$inbox" PV-99999999-r1.pdf "$a_sha" $((a_size + 5)) "$fixtures/a.pdf"); st=$?
expect_err "truncated input rejected" SIZE "$out" "$st"
expect_no_file "no final file after interrupted upload" "$inbox/PV-99999999-r1.pdf"
incoming_empty "no temp files left after interrupted upload" "$inbox"

# --- 6. name validation / path traversal --------------------------------------
for badname in '../evil.pdf' 'PV-1234ABCD-r1.pdf/../../evil.pdf' 'sub/PV-1234ABCD-r1.pdf' \
              'PV-1234ABCD-R1.PDF' 'PV-1234abcd-r1.pdf' 'PV-1234ABCD-r1.PDF ' \
              'PV-1234ABCD-r1.pd' 'PV-1234ABCD-r1234567.pdf' 'PV-1234ABCD.pdf' \
              'PV-1234ABCD-r1.pdf.exe'; do
    out=$(put "$inbox" "$badname" "$a_sha" "$a_size" "$fixtures/a.pdf"); st=$?
    case $out in
    "ERR NAME"*) note "rejected invalid name [$badname] -> $out" ;;
    *) bail "name [$badname] should be rejected with ERR NAME, got [$out] (status $st)" ;;
    esac
done
expect_no_file "traversal cannot escape the inbox (../)" "$work/evil.pdf"
expect_no_file "no subdirectory created inside inbox" "$inbox/sub"
[ -z "$(find "$work" -mindepth 1 -maxdepth 1 -name '*.pdf' 2>/dev/null)" ] \
    && note "nothing written outside inbox" || bail "file written outside inbox"

# valid boundary: 6-digit revision and different id are accepted
out=$(put "$inbox" PV-1234ABCD-r123456.pdf "$a_sha" "$a_size" "$fixtures/a.pdf"); st=$?
expect_ok "6-digit revision accepted" "OK PV-1234ABCD-r123456.pdf $a_sha" "$out" "$st"

# --- 7. protocol violations -----------------------------------------------------
out=$(SSH_ORIGINAL_COMMAND="get PV-1234ABCD-r1.pdf $a_sha $a_size" "$script" "$inbox" < "$fixtures/a.pdf"); st=$?
expect_err "wrong verb rejected" USAGE "$out" "$st"
out=$(SSH_ORIGINAL_COMMAND="" "$script" "$inbox" < "$fixtures/a.pdf"); st=$?
expect_err "empty SSH_ORIGINAL_COMMAND rejected" USAGE "$out" "$st"
out=$(SSH_ORIGINAL_COMMAND="put PV-1234ABCD-r1.pdf" "$script" "$inbox" < "$fixtures/a.pdf"); st=$?
expect_err "incomplete command rejected" USAGE "$out" "$st"
out=$(SSH_ORIGINAL_COMMAND="put PV-1234ABCD-r1.pdf $a_sha $a_size extra" "$script" "$inbox" < "$fixtures/a.pdf"); st=$?
expect_err "trailing garbage rejected" USAGE "$out" "$st"
out=$(SSH_ORIGINAL_COMMAND="put PV-1234ABCD-r1.pdf ZZZZ $a_size" "$script" "$inbox" < "$fixtures/a.pdf"); st=$?
expect_err "malformed sha rejected" CHECKSUM "$out" "$st"
out=$(SSH_ORIGINAL_COMMAND="put PV-1234ABCD-r1.pdf $a_sha -5" "$script" "$inbox" < "$fixtures/a.pdf"); st=$?
expect_err "negative size rejected" SIZE "$out" "$st"
out=$("$script" "$work/no-such-inbox" < "$fixtures/a.pdf"); st=$?
expect_err "missing inbox rejected" USAGE "$out" "$st"
out=$("$script" < "$fixtures/a.pdf"); st=$?
expect_err "missing inbox argument rejected" USAGE "$out" "$st"

# --- 8. non-writable inbox (skipped when running as root) ----------------------
if [ "$(id -u)" -eq 0 ]; then
    printf 'skip non-writable inbox test (running as root)\n'
else
    inbox_ro="$work/inbox-ro"
    mkdir -p "$inbox_ro"
    chmod 500 "$inbox_ro"
    out=$(put "$inbox_ro" PV-1234ABCD-r1.pdf "$a_sha" "$a_size" "$fixtures/a.pdf"); st=$?
    expect_err "non-writable inbox fails" TMP "$out" "$st"
    chmod 700 "$inbox_ro"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
rm -rf "$work"
[ "$failed" -eq 0 ] || exit 1
