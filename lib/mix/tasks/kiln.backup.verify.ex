defmodule Mix.Tasks.Kiln.Backup.Verify do
  @shortdoc "Re-check a backup's files on this host without recording anything"

  @moduledoc """
  Re-check a backup's files here: each file's digest and size, the
  sidecar, and the dump's table of contents (`pg_restore --list`). Records
  nothing (`KilnCMS.Backups.Verify`).

      mix kiln.backup.verify <stamp|id> [--json]

  `bin/backup verify` in a release. Flags, JSON keys and exit codes (0, 1,
  or 2 for a usage error) are `KilnCMS.Backups.CLI`'s; see
  `docs/backup-cli.md`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: KilnCMS.Backups.CLI.mix_main("verify", argv)
end
