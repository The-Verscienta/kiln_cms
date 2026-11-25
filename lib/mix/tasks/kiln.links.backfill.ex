defmodule Mix.Tasks.Kiln.Links.Backfill do
  @shortdoc "Write the reference edges for :reference custom field values"

  @moduledoc """
  Write a `content_links` edge for every top-level `:reference` custom field
  value that has none, single or list, realign the position and link values
  of the edges that drifted, and delete the reference edges no stored value
  holds (#1594, #2742).

      mix kiln.links.backfill

  The upgrade to 1.1 runs this once, as a data migration. Run it again after
  restoring a backup taken before the upgrade, or after writing
  `custom_fields` outside the application (a raw SQL import). Idempotent.

  Run it in a quiet period. A save landing mid-run can be realigned to the
  position or link values its value held when the run read it, and a save
  that removes a target can be crossed by the run's insert, which leaves a
  stale edge holding an `on_target_delete: :restrict` target. Either lasts
  until that record's next changing save.
  See `KilnCMS.CMS.ContentLinks.Backfill`.

  In a release (no Mix):
  `bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    %{inserted: inserted, updated: updated, deleted: deleted} =
      KilnCMS.CMS.ContentLinks.Backfill.run()

    Mix.shell().info(
      "Reference links: #{inserted} written, #{updated} realigned, #{deleted} removed."
    )
  end
end
