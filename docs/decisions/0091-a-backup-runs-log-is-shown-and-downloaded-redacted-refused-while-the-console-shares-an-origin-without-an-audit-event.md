# 0091. A backup run's log is shown and downloaded redacted, refused while the console shares an origin, without an audit event

- **Status** — accepted (2026-11-27).
- **References** — [#2230](https://github.com/The-Verscienta/kiln_cms/issues/2230)
  (backup logs and progress; this is its log viewer, not live progress);
  [#2231](https://github.com/The-Verscienta/kiln_cms/issues/2231) (the tabbed
  Backups page; this adds its Log tab);
  [#1661](https://github.com/The-Verscienta/kiln_cms/issues/1661) (code
  injection is same-origin with the console until `KILN_CONSOLE_HOST` is set;
  [threat model](../threat-model.md), residual risk 16);
  [ADR 0033](0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md)
  (History is rows the pipeline writes);
  [ADR 0089](0089-a-platform-admin-downloads-a-local-backup-file-through-a-one-minute-link-and-never-while-the-console-shares-an-origin.md)
  (the backup file download and its origin refusal). The guide is
  [Read and download the log of a backup](../backups.md#read-and-download-the-log-of-a-backup).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Added ([long form](../changelog/unreleased.md#backup-log-viewer)).

## The problem

Every backup run stores a structured log (`KilnCMS.Backups.Run.log`, at most
200 entries, `KilnCMS.Backups.Log.cap/1`), and until now nothing showed it.
History shows a run's outcome: status, components, size, destinations and
the run's error. The log holds more than that:

- the whole step sequence, with timings;
- lines taken from `pg_dump` and rclone stderr, which can carry hosts, paths,
  remote names and terminal escape sequences;
- retention lines naming what was deleted on each destination, across every
  organization's backups, since a backup covers the whole instance.

#2230 asks for a log view and a download. Four questions outlive the
release: what makes a stored line safe to show now, whether the log is
refused while the console shares an origin as the file download is, how a
plain `GET` download is kept from being spent by another site, and whether
reading a log is audited.

## The decision

### Redacted again at read time, and sanitized

`Log.cap/1` redacts each line when it is stored, with the secrets that
process knew then. `KilnCMS.Backups.LogText` redacts every message, step
name, trigger and the run's `error` again each time a log is shown or
downloaded, with the secrets known now: the `PGPASSWORD`
`Backups.pg_connection/1` derives from `DATABASE_URL` (`LogText.read_env/0`),
the process's own secret variables, and `KilnCMS.Backups.Redact`'s patterns.
A secret set or rotated later, or a pattern a later release adds, then
applies to old rows without rewriting them, which ADR 0033 reserves for the
pipeline.

The limit is stated rather than hidden: a secret is removed literally only
when this process knows it now. A destination's credentials are removed by
pattern (URL userinfo, `key=value`), never by value, and a password the
database URL no longer carries is not known at all.

`LogText.sanitize_display/1` replaces C0 controls but tab and newline, DEL,
the C1 controls and the bidirectional overrides and isolates with U+FFFD, on
the page and in the file. The download is a text file someone will `cat`;
an escape sequence from rclone's stderr must not reach their terminal, and a
bidi override must not make a line read as something it isn't.

The page and the file both come from `LogText`, so they say the same thing.

### Refused while the console shares an origin

The Log tab (`KilnCMSWeb.BackupLogLive`) and the download
(`KilnCMSWeb.BackupLogController`) follow the file download's rule,
`Backups.download_refusal/0`: with `KILN_CONSOLE_HOST` unset and more than
one organization, or while that can't be told, the tab reads no run and
shows a note, and the download answers `403` `console_shares_origin`. The
tab asks again on every patch and every poll, so a verdict that changes
mid-session hides the log at the next one.

The log is not a dump, but it is a map of every organization's backups:
where they go, under what names, how long each step takes and what failed.
A same-origin script running in a platform admin's browser could read it
from the page or the download. It follows the download's rule rather than
the security-log export's, which is not refused, because what it names
spans every tenant's backups.

**History stays ungated.** The History page shows outcomes, destinations
and errors, and this decision does not refuse it. That is a residual, the
same as every other console page under residual 16: `KILN_CONSOLE_HOST`
remains the answer. History's **View log** links stay, and lead to the
note.

### A plain GET, checked with Fetch Metadata

The download is `GET /editor/backups/runs/:id/log.txt` with no token. It
changes nothing, the path carries only the run's id, and a cross-site `GET`
can only start a download in the admin's own browser, which the same-origin
policy keeps the other site from reading. A one-minute token like ADR 0089's
would protect a body that a cross-site request can't read anyway.

What a cross-site `GET` could still do is spend the admin's `:export` rate
bucket: an `<img>` on an organization's site under the same registrable
domain is a same-site request, so the Lax session cookie reaches it, and
ten of them a minute would lock the admin out of backup file downloads and
security-log exports. So the controller checks Fetch Metadata before it
charges: a request that sends `Sec-Fetch-Site` must say `same-origin` or
`none` (a typed URL or a bookmark), and one that sends `Sec-Fetch-Dest` must
say `document` (the Download link) or `empty` (a same-origin `fetch`), else
`403` `cross_site_request`. A request without the headers is let through:
browsers send them, and a client that omits them (curl, an older browser) is
spending its own bucket on purpose.

The checks run in a fixed order, and only a request that passes the
platform-admin, origin and Fetch Metadata checks is charged: platform admin
(`403` `admin_required`), origin (`403` `console_shares_origin`), Fetch
Metadata (`403` `cross_site_request`), the `:export` bucket (`429`), then
the run read as the admin (`404` `not_found`, the same for a malformed id,
an unknown run and a refused read).

### Logged, not audited

A log download records no instance security event; it logs one
`Logger.info` line (`backup log download user_id=… run_id=… stamp=…
entries=…`), as the instance security-log export does. A file download is
audited before any byte (ADR 0089) because the file is every organization's
data. A log is redacted twice and holds no content, accounts or hashes, so
it is treated like the security-log export, which is logged the same way,
not like the dump. Viewing the Log tab records nothing either.

## Rejected

- **Showing the log without the origin refusal**, as the security-log export
  is: the log names every organization's destinations and paths, so it
  takes the stricter rule.
- **Gating History in the same change.** History shows less than the log,
  and refusing it is a decision about the whole Backups page, not about the
  log. Left as part of residual 16.
- **A token, as for the file download.** It protects nothing a cross-site
  `GET` can read; Fetch Metadata covers the one real effect, the bucket.
- **Refusing requests without Fetch Metadata.** That would break curl and
  older browsers to stop a request a browser doesn't make.
- **An audit event per download** (above).
- **Rewriting stored rows when a secret is learned.** The pipeline owns the
  rows (ADR 0033), and a read-time pass reaches every old row at once.

## When to revisit

- **History gains its own origin refusal**, or the console gets its own
  origin by default: then the "History stays ungated" residual goes.
- **Live progress (the rest of #2230)** adds lines between step boundaries:
  every new surface that shows them must go through `LogText`.
- **A destination's credentials become known by value** to the reading
  process: add them to `LogText.read_env/0`.
