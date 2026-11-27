# 0087. The backup command line reads beside the node and writes inside it, and prunes only inside a backup

- **Status** — accepted (2026-11-26).
- **References** — [#2234](https://github.com/The-Verscienta/kiln_cms/issues/2234)
  (backup CLI parity; this is part of it, not all of it);
  [#2225](https://github.com/The-Verscienta/kiln_cms/issues/2225) (destination
  rescan, which `rescan` waits for);
  [ADR 0033](0033-backup-history-is-rows-only-the-backup-pipeline-writes-and-the-files-stay-the-truth.md)
  (only the backup pipeline writes History, and only the backup that wrote a
  file marks it verified);
  [ADR 0064](0064-retention-on-a-backup-destination-deletes-only-what-this-installation-sent-there.md)
  (what retention may delete on a destination);
  [ADR 0067](0067-a-backup-steps-temporary-files-are-its-own-and-only-their-rename-is-fenced.md)
  (the prune step's fenced deletes). The guide is
  [Backups from the command line](../backup-cli.md).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Added ([long form](../changelog/unreleased.md#backup-cli)).

## The problem

Everything the Backups page does was reachable from a release console only as
hand-typed Elixir through `bin/kiln_cms rpc` (`KilnCMS.Backups.request/2`,
`Retention.run(dir, dry_run: true)`, `Importer.retry_failed/0`), with no
stable output and an exit status that said only whether the expression
raised. `bin/backup` and `mix kiln.backup.*` give operators and scripts
`list`, `run`, `verify`, `prune` and `rescan`, with `--json` and exit codes
0, 1 and 2.

Four questions outlive the release:

- Which VM runs each command: the serving node, or a VM of its own?
- How does an exit code get out of `eval` and `rpc` without stopping the
  serving node?
- May the command line delete backups?
- May it record what it checked?

## The decision

### Reads run beside the node, writes inside it

`list` and `verify` run through `bin/kiln_cms eval`, in a short-lived VM that
starts only the repo (`KilnCMS.Release.backup/1`). `verify` hashes every file
of a backup, which can be gigabytes, and that must not take schedulers or
memory from the VM serving sites, so `KilnCMS.Backups.CLI` refuses it under
`rpc` (exit 2, `runs_beside_node`). `list` works there while the application
is down, which is when an operator most wants it.

`run`, `rescan` and `prune` run through `bin/kiln_cms rpc`, inside the serving
node. A backup's steps are jobs on that node's queue, and the importer's
backoff table that `rescan` clears is per node, in `:persistent_term`; a
second VM would start its own queues against the same database, or clear a
table nobody reads. Under `eval` they are refused before `load_app`, so
nothing (repo, cache setting, logger) is touched for them.

The routing is in `rel/overlays/bin/backup` by command name, and the CLI's
mode guard repeats it, so a command that reaches the wrong side by any other
route is still refused.

The arguments travel newline-joined and base64-encoded inside a string
literal. The base64 alphabet holds no quote, backslash, `#{` or `$`, so
nothing an operator types is ever part of the evaluated expression.

The Mix tasks are the third mode. A checkout's `app.start` would start every
Oban queue and the backup heartbeat against whatever database it points at,
so the tasks start Oban in `testing: :manual` with the heartbeat off; a
checkout's `run` only inserts the jobs, and the serving application runs them.

### The exit code is `exit({:shutdown, code})`

`KilnCMS.Backups.CLI.main/2` never prints or halts; it returns
`{exit_code, output}`. The release side prints and, for a non-zero code,
calls `exit({:shutdown, code})`.

`System.halt/1` is the obvious way to set an exit status, and under `rpc` it
would stop the serving node. Under `rpc`, Elixir 1.20's Kernel.CLI
evaluates the expression on the server inside a `try … catch`, so the exit
stays in that call's process; the client re-raises it, and a
`{:shutdown, n}` exit becomes exit status `n` with no stack trace. `eval`
behaves the same.

That server-side function is undocumented. `KilnCMS.ReleaseBackupTest` pins
it with canaries: one calls it directly and expects the caught exit, others
run `elixir -e` with a raised and a plain `{:shutdown, 2}` exit and expect
status 2, and a source check fails any `System.halt`, `:erlang.halt` or
`:init.stop` on the CLI path. A toolchain bump that changes the behaviour
fails there, not in production.

### `prune` only reports

`bin/backup prune` is `Retention.run(Backups.dir(), dry_run: true)`, which
returns after planning: no delete, no `.good` or `.hold` marker, no
`mark_pruned`. A real prune is the prune step of every backup's chain,
fenced by the step's lease (`Steps.prune_opts/2`: `:under_lease` and
`:discard`, ADR 0067), and on destinations bounded by ADR 0064's ownership
rule. The CLI points at `bin/backup run` for a prune now.

Rejected: a prune requested through the chain or the lock. That needs a new
step atom in `Lock`, which an older node cannot cast during a rolling deploy,
or a prune-only chain, or a new trigger or flag that `Lock.Actions.Request`
and `Chain` would have to honor. Each is a second path to the one delete
that must stay fenced, for an operation a backup already performs.

Rejected: a CLI prune outside the chain, with no lease. It would race the
prune step of a running backup over the same files, which is the case
ADR 0067's fencing exists for.

The dry run still imports cron-made backups into History first, as every
retention pass does, and a dry run that can't plan is a skipped retention
pass: it logs and emits `[:kiln_cms, :backups, :retention, :skipped]`. That
is accepted: the report must judge cron's backups from their rows, and an
operator whose retention can't plan should hear about it from the same
alert either way.

### `verify` records nothing

`KilnCMS.Backups.Verify` hashes, lists and compares; it writes no Run field,
marker, sidecar or manifest, and never sets an artifact's `verified`. ADR
0033 holds that only the backup that wrote a file vouches for it, and a CLI
that set `verified` would be a second writer of History. A verify that hashed
nothing (every file pruned or off-site only) is a failure, `nothing_local`,
not a pass, and a verify that can't read the backup lock checks nothing
(`lock_unreadable`) rather than hash a backup that may still be written.

## What it leaves open

- `rescan` covers this host's backup directory only.
- `prune` reports each destination's pruning state, not what would be
  deleted there.
- `restore` (#2226) and `unlock` (#2239).
- No release smoke test runs `rpc` in CI; the `rpc` path is covered piece by
  piece (the overlay against a stub release, the release entry, the CLI).

## When to revisit

- **Destination rescan lands (#2225).** It becomes `bin/backup rescan` with a
  destination scope, and it runs inside the node like the local one.
- **A destination dry run.** Listing what would be pruned on a destination
  needs a `dry_run` option in `Retention.run_on_destination/3` that returns its
  plan before deleting. The CLI must call that, not rebuild the plan from the
  inventory and plan functions, which would duplicate ADR 0064's ownership
  rule.
- **A Kiln-side verified action.** If History should record that a backup was
  re-checked, that is a separate action and field written by the pipeline's
  rules, revisiting ADR 0033, not `verify` setting `verified`.
- **Kernel.CLI changes.** If the canaries fail after a toolchain bump, the
  exit-code transport has to be redesigned before the bump merges, not
  patched around with a halt.
