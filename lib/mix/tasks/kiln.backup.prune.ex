defmodule Mix.Tasks.Kiln.Backup.Prune do
  @shortdoc "Report what backup retention would delete (deletes nothing)"

  @moduledoc """
  Report what retention would delete here, and each destination's pruning
  state. Deletes nothing: a real prune runs inside every backup
  (`mix kiln.backup.run`).

      mix kiln.backup.prune [--dry-run] [--json]

  The app this task starts runs no job queue and no backup heartbeat, so a
  checkout pointed at a deployment's database never drains that
  deployment's jobs.

  `bin/backup prune` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  # `KilnCMS.Backups.CLI.switches(:prune)`, written out so the switch contract
  # test can read it; compiling fails when the two differ.
  @switches [json: :boolean, dry_run: :boolean, help: :boolean]
  if @switches != KilnCMS.Backups.CLI.switches(:prune),
    do: raise(CompileError, description: "@switches differ from CLI.switches(:prune)")

  # No `@requirements ["app.start"]`: `CLI.mix_start/0` starts the app
  # without Oban's queues and plugins or the backup heartbeat.
  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("prune", argv)
end
