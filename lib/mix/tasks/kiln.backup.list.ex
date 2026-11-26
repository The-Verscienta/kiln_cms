defmodule Mix.Tasks.Kiln.Backup.List do
  @shortdoc "List recorded backups and whether their files are on this host"

  @moduledoc """
  The newest backups (default 20, at most 100), each one's files on this
  host's disk, and the backup running now.

      mix kiln.backup.list [--limit N] [--json]

  The app this task starts runs no job queue and no backup heartbeat, so a
  checkout pointed at a deployment's database never drains that
  deployment's jobs.

  `bin/backup list` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  # `KilnCMS.Backups.CLI.switches(:list)`, written out so the switch contract
  # test can read it; compiling fails when the two differ.
  @switches [json: :boolean, limit: :integer, help: :boolean]
  if @switches != KilnCMS.Backups.CLI.switches(:list),
    do: raise(CompileError, description: "@switches differ from CLI.switches(:list)")

  # No `@requirements ["app.start"]`: `CLI.mix_start/0` starts the app
  # without Oban's queues and plugins or the backup heartbeat.
  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("list", argv)
end
