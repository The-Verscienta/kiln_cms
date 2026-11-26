defmodule Mix.Tasks.Kiln.Backup.Rescan do
  @shortdoc "Import cron-made backups in this host's backup directory"

  @moduledoc """
  Import the backups cron made in this host's backup directory, clearing
  the import backoff first (`KilnCMS.Backups.Importer.retry_failed/0`).

      mix kiln.backup.rescan [--json]

  The app this task starts runs no job queue and no backup heartbeat, so a
  checkout pointed at a deployment's database never drains that
  deployment's jobs.

  `bin/backup rescan` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  # `KilnCMS.Backups.CLI.switches(:rescan)`, written out so the switch contract
  # test can read it; compiling fails when the two differ.
  @switches [json: :boolean, help: :boolean]
  if @switches != KilnCMS.Backups.CLI.switches(:rescan),
    do: raise(CompileError, description: "@switches differ from CLI.switches(:rescan)")

  # No `@requirements ["app.start"]`: `CLI.mix_start/0` starts the app
  # without Oban's queues and plugins or the backup heartbeat.
  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("rescan", argv)
end
