defmodule Mix.Tasks.Kiln.Backup.Verify do
  @shortdoc "Re-check a backup's files on this host without recording anything"

  @moduledoc """
  Re-check a backup's files here: each file's digest and size, the
  sidecar, and the dump's table of contents (`pg_restore --list`). Records
  nothing (`KilnCMS.Backups.Verify`).

      mix kiln.backup.verify <stamp|id> [--json]

  The app this task starts runs no job queue and no backup heartbeat, so a
  checkout pointed at a deployment's database never drains that
  deployment's jobs.

  `bin/backup verify` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  # `KilnCMS.Backups.CLI.switches(:verify)`, written out so the switch contract
  # test can read it; compiling fails when the two differ.
  @switches [json: :boolean, help: :boolean]
  if @switches != KilnCMS.Backups.CLI.switches(:verify),
    do: raise(CompileError, description: "@switches differ from CLI.switches(:verify)")

  # No `@requirements ["app.start"]`: `CLI.mix_start/0` starts the app
  # without Oban's queues and plugins or the backup heartbeat.
  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("verify", argv)
end
