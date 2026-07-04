defmodule KilnCMS.CMS.Changes.BustFormCache do
  @moduledoc """
  Clears the published-delivery cache after any form (or form-field) write. A
  form may be embedded on any number of published pages via the `:form` block
  — the blast radius isn't a single `{type, slug}` — so this uses
  `Cache.bust_published/0`, the documented wide-radius invalidation (same
  stance as media edits). Forms change rarely; a full clear is cheap.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      KilnCMS.Cache.bust_published()
      {:ok, record}
    end)
  end
end
