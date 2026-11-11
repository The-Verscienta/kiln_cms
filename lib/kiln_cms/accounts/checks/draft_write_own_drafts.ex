defmodule KilnCMS.Accounts.Checks.DraftWriteOwnDrafts do
  @moduledoc """
  The read half of the `:draft_write` API-key scope (#2273): a key may read the
  drafts it authored, so it can load a row before editing it (a JSON:API PATCH
  reads the record under the actor first) and so autosave can coalesce the
  versions of a draft it is editing.

  A filter check, so it narrows a read rather than gating a whole action:

    * on `Content`: rows with `state == :draft` AND `author_id ==` the key owner.
      An in-review, archived or published row is not matched here (published
      content is world-readable through the policy's other clauses anyway), and
      neither is anyone else's draft.
    * on a `*.Version` resource: versions whose source row is such a draft. A
      version's `changes` carry the full snapshot, so history follows the same
      scope as the document. Once a person moves the draft on (review, publish),
      the key stops seeing its history too.

      This is scoped by owner, not by key, so a second key on the same owner
      reads the history of the first key's drafts (it can edit them, and its
      autosaves coalesce over that history). That is why the provenance
      columns, which ARE per key (`DraftWriteOwnProvenance`), are kept out of
      version `changes` altogether (`ignore_attributes` in `Content`).

  Matches nothing for any actor that is not authenticated by a `:draft_write`
  key, so adding it as an `authorize_if` alongside the editor grant widens
  nothing for anyone else.
  """
  use Ash.Policy.FilterCheck

  alias KilnCMS.Accounts.Checks.DraftWriteKey

  @impl Ash.Policy.Check
  def describe(_opts), do: "a draft-write API key reading the drafts it authored"

  @impl Ash.Policy.FilterCheck
  def filter(actor, %{resource: resource}, _opts) do
    cond do
      not DraftWriteKey.draft_write?(actor) or is_nil(actor.id) ->
        false

      Ash.Resource.Info.relationship(resource, :version_source) ->
        expr(exists(version_source, state == :draft and author_id == ^actor.id))

      true ->
        expr(state == :draft and author_id == ^actor.id)
    end
  end
end
