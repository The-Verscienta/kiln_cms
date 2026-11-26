defmodule Mix.Tasks.Kiln.Backup.Run do
  @shortdoc "Ask for a backup now, optionally waiting for it"

  @moduledoc """
  Ask for a backup now, as the Backups page does (trigger "console").
  `--wait` follows it until it ends (`--timeout` seconds, default 3 hours);
  stopping the wait doesn't stop the backup.

      mix kiln.backup.run [--components db,media] [--wait [--timeout SECONDS]] [--json]

  `bin/backup run` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("run", argv)
end
