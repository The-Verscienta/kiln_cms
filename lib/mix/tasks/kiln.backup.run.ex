defmodule Mix.Tasks.Kiln.Backup.Run do
  @shortdoc "Ask for a backup now, optionally waiting for it"

  @moduledoc """
  Ask for a backup now, as the Backups page does (trigger "console").
  `--wait` follows it until it ends (`--timeout` seconds, default 3 hours);
  stopping the wait doesn't stop the backup.

      mix kiln.backup.run [--components db,media] [--wait [--timeout SECONDS]] [--json]

  The backup itself is run by the serving application, not by this task:
  the task asks for it (and with `--wait` follows it), and its steps are jobs
  the serving app's queues pick up. With no serving app running against the
  same database, the backup stays queued.

  The app this task starts runs no job queue and no backup heartbeat, so a
  checkout pointed at a deployment's database never drains that
  deployment's jobs.

  `bin/backup run` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  # `KilnCMS.Backups.CLI.switches(:run)`, written out so the switch contract
  # test can read it; compiling fails when the two differ.
  @switches [
    json: :boolean,
    components: :string,
    wait: :boolean,
    timeout: :integer,
    help: :boolean
  ]
  if @switches != KilnCMS.Backups.CLI.switches(:run),
    do: raise(CompileError, description: "@switches differ from CLI.switches(:run)")

  # No `@requirements ["app.start"]`: `CLI.mix_start/0` starts the app
  # without Oban's queues and plugins or the backup heartbeat.
  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("run", argv)
end
