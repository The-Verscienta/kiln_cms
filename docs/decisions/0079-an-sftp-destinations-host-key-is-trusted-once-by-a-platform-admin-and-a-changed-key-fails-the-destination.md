# 0079. An SFTP destination's host key is trusted once by a platform admin, and a changed key fails the destination

- **Status** — accepted (2026-11-20). Amends
  [ADR 0066](0066-an-operator-facing-backup-problem-is-a-notice-row-not-a-run-log-line-or-a-security-event.md)'s
  premise that every instance security event is a person's action and none
  raises a security alert: `backup_destination_host_key_mismatch` is
  neither. Builds on
  [ADR 0069](0069-an-admin-entered-backup-endpoint-is-pinned-per-call-and-only-the-operator-opens-private-hosts.md)
  (where a destination may connect) and
  [ADR 0068](0068-a-resumable-backup-upload-is-recorded-by-the-installation-that-started-it-and-only-it-aborts-it.md)
  (resumable uploads).
- **References** — [#2222](https://github.com/The-Verscienta/kiln_cms/issues/2222)
  and the owner's decisions recorded on it (2026-11-17, 2026-11-19): native
  SFTP over OTP's `:ssh`, host-key pinning with a confirmation, a mismatch
  that fails the destination and writes an instance security event alerting
  the admins, one private-hosts variable per adapter
  (`BACKUP_SFTP_PRIVATE_HOSTS`), no plain FTP.
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md).

## The problem

SSH authenticates the server by its host key. A client that accepts
whatever key it is shown sends its password, or a signature from its key,
to whoever answers at that address: a hijacked DNS name, an ARP spoof on the
LAN, a compromised router. For a backup destination that means the whole
database dump goes there too. OpenSSH's answer is `known_hosts` and a
person typing "yes" once; Kiln has no person at the moment of connecting
(a scheduled backup at 03:00), no per-install file that survives a
redeploy, and several nodes that would each need the same file.

OTP's client has its own answer that is wrong for Kiln: when its key
callback says `false` ("not known"), it asks a yes/no question on the
group leader (`ssh_transport:known_host_key/3`), unless
`silently_accept_hosts` is set, in which case it trusts the key.

## Decision

**The trusted key is a column of the destination, set only by a platform
admin.** `backup_destinations.host_key` holds the key's type, its SHA-256
fingerprint (as `ssh-keygen -lf` prints it), whether it was trusted from a
scan or from a fingerprint the admin typed, and when. It is not one of the
settings, so the edit form and `:update` can't touch it; only
`:trust_host_key` writes it, a platform admin's alone (no system actor,
the backup pipeline included), audited as
`backup_destination_host_key_trusted` with the fingerprint it replaced. The
write is a compare-and-swap on the stored fingerprint, so two admins
trusting different keys at once can't overwrite each other unseen, and it
names the host, port and login the key was read from, which must still be
the row's (they are where the destination writes, so `:update` can't change
them either): a key read from one server never vouches for another.

**Until a key is trusted, nothing is sent.** A new SFTP destination is saved
disabled, the validation refuses enabling it while `host_key` is empty, and
every call refuses before connecting.

**The key is read without logging in.** "Check host key" connects with a key
callback that records the offered key and refuses it, so the connection ends
before user authentication: no password, no signature. The page keeps what
the check found on the server, by destination id; "Trust this key" sends
only the id. An admin who knows the fingerprint already pastes it instead,
and the server is asked for each type Kiln trusts until one matches; one
that matches none is refused ("the server presented no key with that
fingerprint").

**Every connection checks the key before authenticating, and offers only
its type.** The client offers only the trusted key's host key algorithms
(an RSA key with `rsa-sha2-512`/`rsa-sha2-256`, never SHA-1; no SHA-1 key
exchange), and its key callback compares type and fingerprint in constant
time. It answers `true` or `{:error, …}`, **never `false`**, and every
connection also passes `user_interaction: false`,
`silently_accept_hosts: false` and `save_accepted_host: false`, so OTP's
prompt can't be reached even if one of those options is dropped later.

**A changed key fails the destination permanently and is a security
event.** The call answers `{:permanent, "the server's host key changed
(offered SHA256:…, trusted SHA256:…); …"}`. The instance log gets
`backup_destination_host_key_mismatch` (name, kind, both fingerprints, no
actor: it is the server's act), and every platform admin gets the platform
alert `backup_host_key_changed` through the existing alert dispatch
(`KilnCMS.Security.AlertGate`, claimed in the event's transaction). The
alert's delivery reads only the site log, so the claim carries the
destination's name itself, and the alert links to the instance security
log, where its event is. At most
one event and alert per destination per hour, cluster-wide: the first call
to see the mismatch claims it with `ThrottleStore.hit/5` and a limit of
one, the claim-first shape `ScannerGuard` uses, so a retrying step or a
retention pass on another node doesn't flood the log. A server that no
longer offers the trusted key's type at all fails permanently too ("no
longer offers its trusted … host key, or no algorithm Kiln accepts") but
raises nothing: that is a reconfiguration, not a different key. OTP reports
only "Key exchange failed" there, so a server that shares no key exchange
or cipher with Kiln reads the same way.

**The connection can't outlive the call.** `Destination.call/4` kills the
process running the adapter at a deadline or a cancel; OTP keeps the SSH
connection under its own supervisor, which would outlive it. Kiln opens the
TCP socket itself, to the pinned address (ADR 0069), registers it with a
guard process linked to the caller and trapping exits, then hands it to
`:ssh.connect/3`. When the caller dies the guard closes the socket and the
connection, a stalled handshake included.

**Secrets stay out of OTP's state where OTP allows it.** The private key is
given to the key callback as a zero-arity function, so OTP's options (kept
in the connection's state, printed in its crash reports) show
`#Function<…>`. OTP takes a password only as a plain option; it sits in the
connection process's state for the length of a call, as readable as the
vault key is to someone with a shell on the node. Key parsing answers a
fixed set of sentences and never raises with key material in the term.

### Uploads

Resumable as ADR 0068 has it: a random 16-hex token saved before
`<name>.<token>.partial` is created, progress saved after acknowledged
writes, the token the only thing read back from a checkpoint (paths are
built from the settings), the last MiB before the resume point read back
and compared before anything is appended, and anything else starting over.
Writes are at most 128 KiB and reads loop on short answers (OpenSSH's
`sftp-server` drops a session on a message over 256 KiB and clamps reads),
with up to 16 writes in flight. The rename into place uses
`posix-rename@openssh.com` when the server offers it (OTP does so on its
own); a server without it refuses an existing target, which is then
removed and the rename made again, but only once the temporary file is seen
to be still there at its full size: a refusal for any other reason never
costs the file already in place. A step's own temporary files are swept by
later puts; a token's are removed only by `abort_upload/3`, which only
Kiln's upload sweep calls.

What lands is verified by size, and on resume by the read-back of the last
MiB: weaker than Local's and S3's whole-file hash, which over SFTP would
read every byte back across the network. There is no `fsync@openssh.com`
call, so a server crash right after the rename can leave a short file;
the next backup's `{:ok, :already_present}` check hashes a file of the
right size in full before trusting it. OTP's SFTP client can't ask for an
exclusive create (`EXCL`), so a fresh temporary name is checked to be free
before it is opened; with a fresh random token that check only loses a race
nobody runs on purpose.

### Symbolic links

The `db` and `media` folders, a backup file and a temporary file must each
be what they claim, checked with `lstat`, never a link: a link there could
make a listing, a delete or a write reach a file Kiln never put there. The
operator's base path is not checked: NAS layouts route shares through links,
and that path is theirs.

## Rejected

- **A `known_hosts` file.** No per-install file survives a redeploy or is
  shared by the nodes, and the database is already the record of what a
  destination is.
- **Trust on first use without a person.** The first connection is exactly
  the one an attacker on the path would answer.
- **Accepting any key** (`silently_accept_hosts: true`). The credentials
  and the dump go to whoever answers.
- **Storing the key in the settings.** `:update` could change it, and the
  edit form would carry it to the browser and back.
- **No guard process.** Every killed call would leave an SSH connection
  open until the server's idle timeout.
- **One private-hosts variable for every adapter.** The owner chose one per
  adapter: allowing a NAS for S3 must not open its SSH port.
- **Relative paths** (to the login directory). `/home/kiln/backups` and
  `backups` can be the same folder, which the overlap check could not see.
- **Plain FTP.** It sends the password in the clear.

## Consequences

- An SFTP destination takes two steps to set up: save it, then check and
  trust its key, then enable it.
- A server whose key is rotated fails every backup to it until a platform
  admin checks and trusts the new key, and the admins hear of it once an
  hour at most.
- Two SFTP destinations whose paths nest are treated by retention as
  possibly the same folder whatever host, port or login they name, and
  neither is pruned (as #3088 does for S3).

## When to revisit

- If the SDK gains a seam for a plugin destination's server trust, this
  policy can move there.
- Retention's "possible overlap" between SFTP destinations could narrow to
  destinations whose trusted host keys match, since one key identifies one
  server.
- If OTP's SFTP client gains an exclusive create, use it for the temporary
  file.
