defmodule Mix.Tasks.Kiln.Backup.Prune do
  @shortdoc "Report what backup retention would delete (deletes nothing)"

  @moduledoc """
  Report what retention would delete here, and each destination's pruning
  state. Deletes nothing: a real prune runs inside every backup
  (`mix kiln.backup.run`).

      mix kiln.backup.prune [--dry-run] [--json]

  `bin/backup prune` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("prune", argv)
end
