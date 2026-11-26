defmodule Mix.Tasks.Kiln.Backup.List do
  @shortdoc "List recorded backups and whether their files are on this host"

  @moduledoc """
  The newest backups (default 20, at most 100), each one's files on this
  host's disk, and the backup running now.

      mix kiln.backup.list [--limit N] [--json]

  `bin/backup list` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("list", argv)
end
