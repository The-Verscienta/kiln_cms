defmodule KilnCMS.CMS.Changes.KeepSectionLayouts do
  @moduledoc """
  Keeps a type's section layouts (`KilnCMS.CMS.FieldSection`, #2280) in step
  with a `KilnCMS.CMS.FieldDefinition` update or destroy (#2652): a field
  that leaves a section (renamed out of it, its section cleared, moved to
  another owner, or deleted) prunes that section's layout when no top-level
  field of the owner carries the name any more
  (`KilnCMS.CMS.SectionLayouts.prune/2`).

  Here rather than in each caller so every path is covered: the fields admin,
  a field sync import, `KilnCMS.CMS.JoinGraduation`'s retire, and any caller
  to come. A layout left behind is not harmless: the next field filed under
  that name inherits it.

  ## Carry

  An `:update` with `carry_section_layout?: true` (the fields admin's rename)
  first moves the old section's layout to the new name
  (`SectionLayouts.carry/4`): the admin renamed the section, one field at a
  time. Without it nothing moves, so a field sync import stays declarative.

  ## How

  `after_action`, inside the field write's transaction, so both decisions
  are made from a fresh read that sees this write and the rows commit or roll
  back together. It runs as the field write's own actor (and with its
  `authorize?`) in the record's org; a refused read or write fails the field
  write with `KilnCMS.CMS.Errors.SectionLayoutNotKept`, so the change fails
  closed rather than leaving an orphaned row. A read the database itself
  fails (a row it cannot load) aborts the transaction at once, so it fails
  the field write with that error instead, untagged. A write whose section
  and owner are unchanged reads nothing.

  The nested layout writes bust the type registry from their own
  `after_transaction` hooks, which run before this transaction commits;
  `Changes.BustTypeRegistry` busts it again after the commit, so they pass
  `KilnCMS.AfterCommit.context/0`.

  ## Deferred

  A field sync import passes `context: %{section_layouts: :deferred}` and
  reconciles once after all of its writes: a swap (one field from A to B,
  another from B to A) would otherwise prune a layout mid-import. The
  dependent writes `Changes.SyncFieldValues` makes on a rename are not
  deferred and never change `section`, so they read nothing here.
  """
  use Ash.Resource.Change

  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS.Errors.SectionLayoutNotKept
  alias KilnCMS.CMS.SectionLayouts

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, &keep(&1, &2, context))
  end

  defp keep(changeset, result, context) do
    old_owner = SectionLayouts.owner_of(changeset.data)
    old_section = changeset.data.section
    {new_owner, new_section} = after_write(changeset, result)

    cond do
      not is_binary(old_section) or is_nil(old_owner) -> {:ok, result}
      {old_owner, old_section} == {new_owner, new_section} -> {:ok, result}
      changeset.context[:section_layouts] == :deferred -> {:ok, result}
      true -> sync(changeset, result, {old_owner, old_section}, new_section, context)
    end
  end

  # A destroyed field leaves its section; an updated one may have moved.
  defp after_write(%{action_type: :destroy}, _result), do: {nil, nil}
  defp after_write(_changeset, result), do: {SectionLayouts.owner_of(result), result.section}

  defp sync(changeset, result, {owner, old_section}, new_section, context) do
    # `rollback_on_error?: false` hands a refused layout write back here
    # rather than aborting the transaction with the bare error, so it can be
    # tagged; returning the tagged error still rolls the field write back.
    opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.put(:tenant, changeset.data.org_id)
      |> Keyword.put(:context, AfterCommit.context())
      |> Keyword.put(:rollback_on_error?, false)

    carry? =
      Ash.Changeset.get_argument(changeset, :carry_section_layout?) == true and
        SectionLayouts.owner_of(result) == owner and is_binary(new_section)

    with :ok <-
           if(carry?, do: SectionLayouts.carry(owner, old_section, new_section, opts), else: :ok),
         :ok <- SectionLayouts.prune(owner, [only: [old_section]] ++ opts) do
      {:ok, result}
    else
      {:error, reason} ->
        {:error, SectionLayoutNotKept.exception(section: old_section, reason: reason)}
    end
  end
end
