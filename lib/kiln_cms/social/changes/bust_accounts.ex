defmodule KilnCMS.Social.Changes.BustAccounts do
  @moduledoc """
  Drops the cached "does this site have any social account?" answer (#497).

  The reaction asks that question on every publish, so it is cached — which
  means an admin who has just enabled their first account would otherwise watch
  the next few publishes announce nothing, with no error anywhere to explain it.
  Busting on write makes the setting take effect on the next publish.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      KilnCMS.Social.bust(record.org_id)
      {:ok, record}
    end)
  end
end
