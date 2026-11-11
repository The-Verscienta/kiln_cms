defmodule KilnCMS.CMS.Changes.MaskHiddenFields do
  @moduledoc """
  Leaves the private custom fields an editor's read restriction hides
  (`field_read_grants`, #2281) out of the record their write returns.

  `Preparations.MaskPrivateFields` masks what a READ returns, but a create or
  update hands back the record it just wrote — and that is what JSON:API,
  GraphQL, MCP and the console serialize in reply. The write itself is
  untouched (`Changes.RestoreHiddenFields` keeps the hidden values in the row):
  this runs as an `after_transaction` hook, registered last among the
  resource's changes, so no other hook, version or notification builds on the
  masked record.

  Skipped like the read mask: `authorize?: false` writes (internal plumbing
  whose result may be written back), a `KilnCMS.SystemActor`, admins and
  non-editors (a non-editor cannot write content, and the read mask covers
  them).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.HiddenFields

  @impl true
  # authorize?: false — a match on the write's own flag, not a bypass.
  def change(changeset, _opts, %{authorize?: false}), do: changeset
  def change(changeset, _opts, %{actor: %KilnCMS.SystemActor{}}), do: changeset

  def change(changeset, _opts, %{actor: %{} = actor}) do
    if Scoping.effective_tier(actor, changeset) == :editor do
      Ash.Changeset.after_transaction(changeset, fn changeset, result ->
        mask(result, actor, changeset.tenant)
      end)
    else
      changeset
    end
  end

  def change(changeset, _opts, _context), do: changeset

  defp mask({:ok, record}, actor, tenant),
    do: {:ok, HiddenFields.drop(record, HiddenFields.names(actor, record, tenant))}

  defp mask(other, _actor, _tenant), do: other
end
