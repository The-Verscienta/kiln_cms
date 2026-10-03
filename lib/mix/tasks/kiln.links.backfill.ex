defmodule Mix.Tasks.Kiln.Links.Backfill do
  @shortdoc "Write the reference edges for :reference custom field values"

  @moduledoc """
  Write a `content_links` edge for every `:reference` custom field value that
  has none, and delete the reference edges no stored value implies (#1594).

      mix kiln.links.backfill

  The upgrade to 1.1 runs this once, as a data migration. Run it again after
  restoring a backup taken before the upgrade, or after writing
  `custom_fields` outside the application (a raw SQL import). Idempotent. See
  `KilnCMS.CMS.ContentLinks.Backfill`.

  In a release (no Mix):
  `bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    %{inserted: inserted, deleted: deleted} = KilnCMS.CMS.ContentLinks.Backfill.run()
    Mix.shell().info("Reference links: #{inserted} written, #{deleted} removed.")
  end
end
