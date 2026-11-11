defmodule KilnCMS.Accounts.Checks.DraftWriteOwnProvenance do
  @moduledoc """
  Field-policy check for the provenance fields on `Content` (#2273): a
  `:draft_write` API key may see them on the drafts IT created.

  Narrower than `DraftWriteOwnDrafts`, which scopes by the key's *owner*: two
  keys on one owner share an author, but each sees only the rows stamped with
  its own key id. Matches nothing for any actor not authenticated by a
  `:draft_write` key, so adding it beside the editor grant widens nothing for
  anyone else, and nothing for a published row (world-readable, and the
  provenance is not).
  """
  use Ash.Policy.FilterCheck

  alias KilnCMS.Accounts.Checks.DraftWriteKey

  @impl Ash.Policy.Check
  def describe(_opts), do: "a draft-write API key reading the provenance of a draft it created"

  @impl Ash.Policy.FilterCheck
  def filter(%{__metadata__: %{api_key: %{id: key_id}}} = actor, _context, _opts) do
    if DraftWriteKey.draft_write?(actor) and is_binary(key_id) do
      expr(state == :draft and created_via_key_id == ^key_id)
    else
      false
    end
  end

  def filter(_actor, _context, _opts), do: false
end
