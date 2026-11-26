defmodule Mix.Tasks.Kiln.Backup.Rescan do
  @shortdoc "Import cron-made backups in this host's backup directory"

  @moduledoc """
  Import the backups cron made in this host's backup directory, clearing
  the import backoff first (`KilnCMS.Backups.Importer.retry_failed/0`).

      mix kiln.backup.rescan [--json]

  `bin/backup rescan` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("rescan", argv)
end
