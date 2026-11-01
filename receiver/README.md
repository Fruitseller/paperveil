# PaperVeil receiver (`paperveil-receive`)

Server-side counterpart of PaperVeil's transfer module. It is a small POSIX `sh`
script (works on Linux and macOS) that receives **sanitized** export PDFs over
SSH and stores them in an inbox directory — atomically, verified, without
overwriting existing files and without ever writing outside the inbox.

It is deliberately simple: no SFTP server, no library, no daemon. It runs as an
SSH **forced command**, so the connecting key can do exactly one thing: upload
a file with a neutral `PV-…-r…\.pdf` name.

## Protocol

The client invokes:

```sh
ssh -o BatchMode=yes … user@host put <name> <sha256> <size>
```

and streams exactly `<size>` bytes to stdin. Constraints:

- `SSH_ORIGINAL_COMMAND` must be exactly `put <name> <sha256> <size>`.
- `<name>` must fully match `PV-[A-F0-9]{8}-r[0-9]{1,6}\.pdf` (neutral document
  ID + export revision). Anything else — including `/`, `..`, lowercase — is
  rejected with `ERR NAME`.
- `<sha256>` is the lowercase hex SHA-256 of the streamed bytes; `<size>` a
  non-negative integer.

Behavior:

1. Exactly `<size>` bytes are read from stdin into a temp file inside
   `<inbox>/.incoming/` (created with `mktemp`). Fewer bytes (interrupted
   upload) ⇒ `ERR SIZE`, no final file.
2. SHA-256 of the received bytes must equal `<sha256>`, otherwise
   `ERR CHECKSUM`, no final file.
3. The temp file is fsynced where possible (GNU coreutils `sync -d`; a no-op
   elsewhere) and finalised atomically via `ln tmp final`. `ln` fails if the
   target exists, so an existing file is **never** overwritten or truncated.
4. If the final file already exists: identical hash ⇒ idempotent success
   (`OK …`); different hash ⇒ `ERR EXISTS`. Retries never create uncontrolled
   duplicates.
5. On every error the temp file is removed and the script exits non-zero.

Output (single line on stdout): `OK <name> <sha256>` on success,
`ERR <code> <message>` on failure. Error codes: `USAGE`, `NAME`, `SIZE`,
`CHECKSUM`, `TMP`, `WRITE`, `IO`, `EXISTS`, `FINALIZE`.

## Installation

On the receiving server (example paths; adjust to taste):

```sh
# 1. dedicated, unprivileged user — never root, never a shared login
sudo useradd --create-home --shell /usr/sbin/nologin paperveil

# 2. inbox owned by that user
sudo mkdir -p /srv/paperveil/inbox
sudo chown paperveil:paperveil /srv/paperveil/inbox
sudo chmod 700 /srv/paperveil/inbox

# 3. install the script
sudo install -o root -m 755 paperveil-receive /usr/local/bin/paperveil-receive

# 4. forced command in the client's authorized_keys entry (~paperveil/.ssh/authorized_keys)
command="/usr/local/bin/paperveil-receive /srv/paperveil/inbox",restrict ssh-ed25519 AAAAC3NzaC1… paperveil
```

`restrict` disables pty allocation, port forwarding, X11, agent forwarding and
user execution: the key can only run the forced command. `authorized_keys`
must be owned by the receiver user, its `.ssh` directory and the file `700`/`600`.

The key pair is generated on the Mac (never stored in the repository) with
`ssh-keygen -t ed25519`; the private key stays in the user's `~/.ssh` (or a path
configured in PaperVeil as *identity file*).

## Server identity on the client side

PaperVeil always invokes the system OpenSSH client as:

```
/usr/bin/ssh
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=<app-managed known_hosts>
  -o GlobalKnownHostsFile=/dev/null
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  [-i <identity file>] -p <port> user@host -- put <name> <sha256> <size>
```

The app-managed `known_hosts` file starts empty. Before the first transfer the
app fetches the server's ed25519 key with `ssh-keyscan` and shows its
`SHA256:…` fingerprint; the key is only written (pinned) after the user
explicitly confirms that fingerprint out-of-band. An unknown or changed host
key therefore fails the connection — it is never silently accepted — and is
reported as a host-key error, not as a generic network failure.

## Security boundaries and limits

- **The forced command is the upload boundary.** `paperveil-receive` itself
  only writes inside `<inbox>`; the name check rejects traversal before any
  path is built. A working integration test (write attempt outside the inbox)
  is part of `test-receiver.sh`.
- **A Hermes profile (or any other device-management profile) is not a
  security boundary** for this upload path. Profiles restrict the Mac; they do
  not authenticate the server or limit the receiving account. Authorization is
  enforced server-side by `command=…,restrict`, file ownership and, optionally,
  the hardening below.
- The receiver user must not be able to write anywhere it should not
  (chown of the inbox is the minimum). Consider, where the platform allows:
  - `ChrootDirectory` in `sshd_config` for the receiver user (the chroot path
    and all parents must be root-owned; the inbox lives inside), or
  - ACLs / a dedicated filesystem for the inbox, and
  - rate/traffic limits in `sshd_config` (`MaxSessions`, `MaxStartups`),
  - server-side log retention for `sshd` (the protocol output is neutral).
- PaperVeil only uploads **approved, sanitized exports** (never originals,
  blocklists or re-identification data — see `docs/ZIELZUSTAND.md` D02). The
  manifest information travels in the `put` command itself: neutral document
  ID, revision, SHA-256, byte count.
- If the connection drops mid-upload the receiver sees a short read and
  discards the temp file; nothing partial is ever finalised.

## Tests

```sh
sh receiver/test-receiver.sh
```

runs the script locally (simulating sshd by setting `SSH_ORIGINAL_COMMAND`) on
macOS and Ubuntu and covers: success, idempotent retry, same-name-different-content
rejection, checksum mismatch, truncated upload, invalid/traversal names,
protocol violations and non-writable inbox (skipped when run as root).
