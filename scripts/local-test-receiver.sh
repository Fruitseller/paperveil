#!/bin/sh
# Starts a synthetic, local-only transfer target for acceptance tests:
# an unprivileged OpenSSH server on 127.0.0.1 whose single authorized key is
# bound to receiver/paperveil-receive as a forced command (no shell, no sftp).
#
# Usage: scripts/local-test-receiver.sh <dir> [port]     (default port 2222)
# Prints host/port/user/key for PaperVeil → Einstellungen → Übertragung.
# Stop: kill "$(cat <dir>/sshd.pid)"
set -eu
DIR="${1:?usage: $0 <dir> [port]}"; PORT="${2:-2222}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$DIR/inbox"
DIR="$(cd "$DIR" && pwd)"
[ -f "$DIR/hostkey" ] || ssh-keygen -q -t ed25519 -N '' -C paperveil-test-host -f "$DIR/hostkey"
[ -f "$DIR/client" ] || ssh-keygen -q -t ed25519 -N '' -C paperveil-test-client -f "$DIR/client"
printf 'command="/bin/sh %s %s",restrict %s\n' "$ROOT/receiver/paperveil-receive" "$DIR/inbox" "$(cat "$DIR/client.pub")" > "$DIR/authorized_keys"
cat > "$DIR/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/hostkey
AuthorizedKeysFile $DIR/authorized_keys
PidFile $DIR/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding no
CFG
/usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"
sleep 0.5
echo "Testziel läuft: host=127.0.0.1 port=$PORT user=$(id -un) key=$DIR/client inbox=$DIR/inbox"
echo "Erwarteter Hostschlüssel: $(ssh-keygen -lf "$DIR/hostkey.pub")"
