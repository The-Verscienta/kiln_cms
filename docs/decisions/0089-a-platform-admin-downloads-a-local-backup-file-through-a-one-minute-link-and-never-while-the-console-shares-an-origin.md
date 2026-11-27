# 0089. A platform admin downloads a local backup file through a one-minute link, and never while the console shares an origin

- **Status** — accepted (2026-11-26).
- **References** — [#2225](https://github.com/The-Verscienta/kiln_cms/issues/2225)
  (backup file management; this is its download part, not all of it);
  [#1661](https://github.com/The-Verscienta/kiln_cms/issues/1661) and
  [#1688](https://github.com/The-Verscienta/kiln_cms/issues/1688) (code
  injection is same-origin with the console until `KILN_CONSOLE_HOST` is set;
  [threat model](../threat-model.md), residual risk 16);
  [#2490](https://github.com/The-Verscienta/kiln_cms/issues/2490) (tokens bound
  to the browser session);
  [#2539](https://github.com/The-Verscienta/kiln_cms/issues/2539) (a run
  records the backup directory that holds its files);
  [ADR 0011](0011-each-organization-gets-its-own-console-origin-under-the-console-host.md)
  (one console origin per organization);
  [ADR 0033](0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md)
  (History is rows; the files are the truth). The guide is
  [Download the files of a backup](../backups.md#download-the-files-of-a-backup).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Added ([long form](../changelog/unreleased.md#backup-download)).

## The problem

A backup's files could only be taken off the server with a shell: `scp`,
`rsync`, or the destination's own tools. #2225 asks for a download from
History. The file is the most valuable thing Kiln holds: a database dump is
every organization's content, accounts and password hashes. Four questions
outlive the release:

- Who may download, and how is a download recorded?
- How does the browser get the file without a URL that can be logged,
  forwarded or replayed later?
- Which file is served, given a name the client sent?
- What happens when the console shares an origin with tenant sites, so that
  any organization's injected script runs with a platform admin's session?

## The decision

### The platform admin only, audited before any byte

`Backups.Run` gains two generic actions with one implementation
(`KilnCMS.Backups.Run.Actions.Download`): `:check_download`, which runs every
check and writes nothing, and `:download`, which runs the same checks and then
records `backup_downloaded` in the instance security log. Their one policy is
`authorize_if Accounts.Checks.PlatformAdmin`, so the `:backups` system actor
is refused with everyone else: nothing in the pipeline downloads.

The History page's click calls `:check_download`, so a click that sends no
bytes records nothing. The download request calls `:download` immediately
before it sends, and the action returns the file's path only once the event
is written: "recorded before bytes" is the action's contract, not a promise
the controller keeps. An event that can't be written is `503` with nothing
sent.

No migration: a generic action writes no run, `InstanceEvent.type` is checked
app-side only, and metadata is a map. ADR 0033 is unaffected: a download
writes no History row.

### A one-minute, session-bound token, posted in a body

The click mints a `KilnCMSWeb.BackupDownloadToken`: a `Phoenix.Token` under
its own salt, good for 60 seconds, naming the run, the file, the user, the
browser session's jti (as the collab token does since #2490) and the click
node's backup-directory id. A page with no session jti mints nothing.

The page's `BackupDownload` hook posts it in a hidden, CSRF-protected form to
`POST /editor/backups/download`; the answer is an `attachment`, so the page
stays. A body parameter is filtered from the request log by
`:filter_parameters` on every node, an older one included, and never enters
the browser's history or downloads list. `GET` and `HEAD` there answer `405`.

The token is not single-use. A second request with it, within the minute and
from the same session, is checked again, charged against the `:export`
budget and recorded again. A single-use token would need a table or a
cluster-wide store for 60 seconds of protection against a replay that
already needs the admin's session cookie.

### The name is compared with the row, never parsed

The file name from the token is accepted only if it equals, byte for byte,
one of the names `KilnCMS.Backups.Artifact.checked_files/2` derives from the
run's own row (each artifact's files, which Verify checks the same way), or
the `.sha256` sidecar of such an artifact. Before that it must be a binary of
at most 255 bytes with no `/`, `\` or NUL. The path is built from
`Backups.dir/0`, the kind's subdirectory and the matched name, and must stay
under that subdirectory. `File.lstat` must find a regular file. A file marked
pruned here is refused even if a file of that name is still on disk. Only
`:app` and `:imported` rows are served: an origin a later release adds (a
rescanned `:found`) is refused until it has a decision of its own. Every file
refusal is the same `404`.

The controller `lstat`s the path again right before `send_file` and sends
only the same regular file (inode, device, size, mtime). The event is already
written by then, so a file that changed or went in that gap leaves an event
for bytes that were not sent, with a warning in the server log saying so.
Recording after the send was rejected: a dropped event would leave bytes sent
with no trace, which is the worse error.

### Refused while the console shares an origin

Both actions refuse (`:console_shares_origin`) while `KILN_CONSOLE_HOST` is
unset and there is more than one organization, and also while that can't be
told: an organization count that can't be read, or a node whose
`KilnCMSWeb.Tenant.OrgCount` verdict is not `:single`. This fails closed,
unlike the boot warning `Tenant.console_shares_origin?/1`, which treats an
unknown count as "not shared". The page shows one note in place of every
Download menu, saying to set `KILN_CONSOLE_HOST` or copy the files from the
server.

Rejected: a fresh second-factor step-up instead. The injected script shares
the admin's origin, so it can satisfy or spoof any step-up: a recent
second-factor mark is already fresh for a script that runs just after
sign-in, a TOTP prompt can be faked by the site's own head or footer code and
the code relayed, and a passkey assertion is checked against allowed origins,
which on a shared origin include the tenant site, so the admin taps the key
for the script. A refusal is deterministic and testable, and matches residual
16's existing verdict, "closed by configuration".

**This closes the direct download path only.** Other console actions a
same-origin script could take with a platform admin's session have no origin
refusal; `KILN_CONSOLE_HOST` remains the answer to residual 16.

### Multi-node

A run that records a `dir_id` (#2539) is served only from that backup
directory; a directory id that can't be read refuses. Because the click
(the LiveView socket) and the request (plain HTTP) can reach different nodes,
the token carries the click node's directory id, and a request answered by a
node with another one is `409` "this link reached a different server", not a
bare `404`. Operators route `/editor/backups*` to one node or share
`BACKUP_DIR`. For an unpinned row (imported, or from before #2539) on nodes
that both have no `.kiln-dir-id`, the two can't be told apart and the `409`
can't fire.

## Rejected

- A static mount on `BACKUP_DIR`, a path or file name in the URL, or trusting
  the token's file name without matching it against the row again.
- An unsigned, long-lived or render-time URL: the page re-renders every 3
  seconds while a backup is in flight, and stays open for hours otherwise, so
  a render-time link would either expire under the reader or live long
  enough to be forwarded.
- Recording on the click, which would log downloads that never happened.
- Downloading destination copies, or zipping a whole set on the fly (no
  `Content-Length`, CPU on the web node, and an archive the restore runbook
  doesn't describe). One file per click, no `Range`.
- A rate bucket of its own. Downloads share `:export` (10 a minute per
  account per node) with content-list and security-log exports.
- Making `backup_downloaded` alertable now. The recipients would be the
  platform admins, usually the person who downloaded, and platform alert
  kinds are on by default and can't be muted except `api_key_rate_limited`.

## Open questions for the owner

- **Single-org installs.** Downloads stay allowed with `KILN_CONSOLE_HOST`
  unset when there is one organization, following residual 16's verdict that
  the org admin and the operator are then one party. Should they instead be
  refused whenever the console host is unset and code injection was set by
  someone who is not a platform admin?
- **Alerts.** Add an optional `backup_downloaded` platform alert kind, off by
  default?
- **Limits.** Is the shared `:export` budget enough for a media set of many
  parts, or should downloads get their own bucket?

## When to revisit

- **Destination changes and backups get the same origin refusal.** Then the
  shared-origin paragraph above can say the whole dump path is closed, not
  only the direct one.
- **Rescan lands (#2225)** with a `:found` origin: decide whether its rows'
  files are served, and add it to `served_origin?/1` only then.
- **Restore (#2226)** or an upload: they need their own decision; nothing
  here covers writing files.
