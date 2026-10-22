defmodule Mix.Tasks.Kiln.Media.Resnapshot do
  @shortdoc "Re-take stored :media custom-field snapshots from the current library items"

  @moduledoc """
  Brings every stored `:media` custom-field value up to the current media
  shape (`KilnCMS.Media.Snapshot`: dimensions, MIME type, focal point and
  variants) — see `KilnCMS.Media.Resnapshot`.

      mix kiln.media.resnapshot                 # dry run: report, write nothing
      mix kiln.media.resnapshot --apply
      mix kiln.media.resnapshot --org <uuid>    # one site (default: every site)

  A **dry run is the default**: each record's write is built and compared, and
  the count is what `--apply` would write. Re-running is safe — a record
  whose snapshots are already current is not written.

  Fired artifacts do not need this (they re-read the items on every fire, and
  an artifact older than the media shape re-fires on its next read); this is
  for the value stored on the row, which JSON:API and GraphQL serve.
  """

  use Mix.Task

  alias KilnCMS.Media.Resnapshot

  @switches [apply: :boolean, org: :string, batch: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    dry_run? = opts[:apply] != true
    run_opts = [dry_run?: dry_run?] ++ Keyword.take(opts, [:batch])

    org_ids = if opts[:org], do: [opts[:org]], else: KilnCMS.Accounts.list_org_ids()

    failed =
      Enum.reduce(org_ids, 0, fn org_id, failed ->
        report = Resnapshot.run(org_id, run_opts)
        Mix.shell().info(Resnapshot.describe(report, org_id, dry_run?))
        failed + length(report.failed)
      end)

    if failed > 0, do: Mix.raise("#{failed} record(s) could not be re-snapshotted")
  end
end
