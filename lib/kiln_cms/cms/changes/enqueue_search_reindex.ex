defmodule KilnCMS.CMS.Changes.EnqueueSearchReindex do
  @moduledoc """
  After any write to a site's `KilnCMS.CMS.SiteMeilisearch` row, enqueue a full
  reindex of that site (`KilnCMS.Search.MeilisearchWorker`, `"op" =>
  "reindex"`).

  Switching instance — on, off, a new URL, a new index, a removed row — leaves
  the instance the site now resolves to without the site's content. The job
  resolves the instance when it runs, not now, so it always fills the one in
  use at that moment; if there is none (no row and no `MEILI_URL`) it does
  nothing.

  The job is inserted inside the write's transaction (Oban shares the repo), so
  a write that rolls back enqueues nothing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, row ->
      {:ok, _job} = KilnCMS.Search.MeilisearchWorker.enqueue_reindex(row.org_id)
      {:ok, row}
    end)
  end
end
