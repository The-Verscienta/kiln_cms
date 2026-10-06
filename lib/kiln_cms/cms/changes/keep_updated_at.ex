defmodule KilnCMS.CMS.Changes.KeepUpdatedAt do
  @moduledoc """
  Leaves a content record's `updated_at` where it was, on an update action
  that writes only a column *derived* from the content — `:reindex_search_text`
  and `:set_embedding`.

  `updated_at` is what a reader is told is the date the content last
  changed: the "Last updated" line, JSON-LD `dateModified`, a feed's
  `<updated>`, a "newest first" sort. Recomputing the search text or the
  vector of a document nobody edited is not a change to it, and a
  re-index of a whole type (flipping a field's `searchable` flag, a
  `mix kiln.refire_all`) used to restamp every published document of it
  with the time of the sweep — the opposite of what `KilnCMS.Firing.Sweep`
  promises ("no `updated_at` churn").

  Ash sets an update default for every attribute the changeset is not
  already changing, and setting `updated_at` to its current value does not
  count as changing it. An *atomic* update does: `updated_at = updated_at`
  in the `UPDATE` itself, so the default is skipped and the stored value
  is kept, without a read-modify-write race against a concurrent editorial
  save (whose own new `updated_at` it can never overwrite).

  Not for anything an editor does. An editorial write is a change, and its
  timestamp is the point.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.atomic_update(changeset, :updated_at, Ash.Expr.expr(updated_at))
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, %{updated_at: Ash.Expr.expr(updated_at)}}
  end
end
