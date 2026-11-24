# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="condition-text-ops"></a>

- **Conditional fields can match text (#3270).** A **Show when** or **Required when** test in `/editor/fields` now offers **contains**, **does not contain**, **starts with** and **ends with** when it reads a text, URL or choice field: "show **Download notes** when **File URL** ends with `.pdf`". In a rule these are the operators `contains`, `not_contains`, `starts_with` and `ends_with`, each with a non-blank string `value`.
  - **Matching ignores case and surrounding spaces.** Both sides are trimmed, as for `eq`, and lowercased. The editor's evaluator and the server agree on non-ASCII text too (a Greek word-final sigma folds to ς on both); one shared fixture holds them to it.
  - **Lists and non-text values.** On a multiple field a test holds when any item matches, so **does not contain** holds only when no item contains the text. An empty value contains nothing. A number, yes/no or date field cannot use these tests: the definition is refused, and so is retyping a field to a non-text type while a text test reads it.
  - **Additive.** No migration. An older release reading a rule with one of these operators treats it as a rule it cannot read: the field is shown and not required, and the definition cannot be saved until the rule is changed.

## Fixed

<a id="api-key-unknown-scope"></a>

- **An API key whose scope this release doesn't know loads, and authenticates as nothing (#2604).** A key's `access` scope was a plain atom column, so a key minted by a newer release with a scope this one lacks (met on an older node during a rolling deploy, or after a rollback) failed every read that touched it: the key's own lookup at sign-in, the whole list at `/editor/api-keys`, revoking it, revoking an erased account's keys (erasure, the erasure backfill) and revoking a squatter's keys on invitation takeover. `access` is now a `KilnCMS.Types.KnownAtom`, as `docs/releasing.md` ("New values in an atom column") asks of a column that will grow, so the key loads with its scope as `%UnknownAtom{}`, and all of those work again.
  - **Refused, never read-only.** A new scope may grant less than read, so such a key must not fall back to its owner's reads. `User.valid_api_keys` admits only the scopes this release knows (`KilnCMS.Accounts.ApiKey.Scope.known/0`), so the key is refused exactly as a revoked one: the same `401` on JSON:API, GraphQL, `/mcp`, `GET /api/feed`, `GET /api/graphql/schema.graphql` and `POST /api/keys/rotate`, and anonymous on the bridge socket. Nothing is logged on the refusal: the key is simply not found, and logging it would cost an extra read on the unauthenticated path. That filter is the only gate for now; the drafts-only read clamps match `:draft_write` exactly, and hardening them is [#3316](https://github.com/The-Verscienta/kiln_cms/issues/3316).
  - **Rotation reuse still counts.** A rotated-away key presented more than 120 seconds after its rotation still revokes its chain, whatever its scope reads as; a live unknown-scope key with no successor is refused and burns nothing.
  - **In the console.** `/editor/api-keys` lists the key as **Unrecognized scope (name)**, with the stored name, and status **Not accepted** (an expired one reads **Expired**, as does an erased owner's). The status's tooltip says a release that knows the scope accepts it again, so revoke it if that isn't wanted. **Revoke** works as for any key.
  - **Security posture.** `core.api_keys` counts such keys in a new fact, `unrecognized_scope_keys`, and is **Review** for them, never **Fix now**; they are also named in **Details** when the check fails for an administrator's read-write key. `valid_keys` now counts only the keys that sign in on this release. During a rollout that adds a scope, older nodes warn and newer ones pass, and the JSON endpoint caches each node's answer for up to 30 seconds. The posture JSON contract is additive, so the new fact is not a breaking change.
  - **No migration; rolling the pin back is safe.** The column stays text. Mint keys with a new scope only once every node runs the release that added it; see `docs/releasing.md`.

<a id="external-command-group-kill"></a>

- **External programs are stopped by a process-group kill from inside, never by a pid from the VM (#2624).** `KilnCMS.ExternalCommand` runs qpdf, ffmpeg/ffprobe, `pg_dump`, `pg_restore`, `tar` and `rclone`. It used to stop a program on a deadline, a canceled or fenced backup step, or its caller's death by sending a kill to the program's OS pid from the VM. By the time that kill was sent the program could already have exited and been reaped, and its pid reused by an unrelated process. The program now runs under a fixed `/bin/sh` wrapper whose stdin watcher, when the port closes, sends SIGKILL to its own process group: the wrapper, the program, anything the program started, and the watcher. A process group's id can't be reused while any member is alive, so the kill can't reach a stranger, and it needs no binary on `PATH`.
  - **More is stopped.** A stopped program's own children (an ffmpeg helper, a `tar` filter) stop too, and the program stops when the VM exits, since the port's pipe closes with it.
  - **What a caller can see.** The program's stdin is `/dev/null`. A missing program returns exit status 127 and a non-executable one 126, instead of raising. The program must be given as an absolute path (every caller already passes a `System.find_executable/1` result); anything else raises `ArgumentError`. The deadline kill finishes just after `run/4` returns `:timeout`, not before.
  - **Orphans.** The killed processes are reparented to PID 1, which must reap them. The release image's `/bin/sh` command does, and so does the VM when it is PID 1. A custom entrypoint that leaves some other program as PID 1 should use an init such as `tini` (`docker run --init`).
