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

  Where the field was is read in a `before_action`, inside the field
  write's transaction and locked `FOR UPDATE`, never taken from the struct
  the write was built from: a form opened before another admin moved the
  field would otherwise prune the section it no longer is in and orphan the
  one it is. Where it goes is that row with the write's own attribute
  changes. The layouts are then kept in an `after_action`, in the same
  transaction, so both decisions are made from a fresh read that sees this
  write and the rows commit or roll back together. It runs as the field write's own actor (and with its
  `authorize?`) in the record's org; a refused read or write fails the field
  write with `KilnCMS.CMS.Errors.SectionLayoutNotKept`, so the change fails
  closed rather than leaving an orphaned row. That includes a layout read
  that fails outright (a row this release cannot load): Ash rolls a
  transaction back at once on such a read, so the layouts are kept inside a
  nested transaction, where that rollback ends and its error is tagged; the
  field write then rolls back with it (#3062). The fields admin names the
  cause from the tag. An update that sets none of the columns placing the
  field (its section and owner) reads nothing, and neither does a deferred
  one.

  A field another write deleted since the struct was loaded is not a layout
  failure: the locked re-read's `Ash.Error.Query.NotFound` fails the write
  as it is, untagged, so a concurrent delete is not reported as a layout
  that could not be removed. Safe to pass through: that read runs with
  `authorize_with: :error`, so a row the actor may not see is `Forbidden`,
  never `NotFound`, and is still tagged.

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
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Errors.SectionLayoutNotKept
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.SectionLayouts

  @impl true
  def change(changeset, _opts, context) do
    if moves?(changeset) and changeset.context[:section_layouts] != :deferred do
      changeset
      |> Ash.Changeset.before_action(&current(&1, context))
      |> Ash.Changeset.after_action(&keep(&1, &2, context))
    else
      changeset
    end
  end

  # The columns that decide which section of which owner a field is in. A
  # write that changes none of them moves nothing, whatever the struct it
  # was built from says, so it reads nothing.
  @placement [
    :section,
    :content_type,
    :type_definition_id,
    :link_of_id,
    :group_of_id,
    :flex_of_id
  ]

  defp moves?(%{action_type: :destroy}), do: true

  defp moves?(changeset),
    do: Enum.any?(@placement, &Ash.Changeset.changing_attribute?(changeset, &1))

  # Where the field is now, not where the struct the write was built from
  # put it: a form opened minutes ago may predate another admin's move, and
  # deciding from it would prune the wrong section and orphan the right one.
  # Read inside the write's transaction and locked, so no other write moves
  # the field between this read and the write; as the write's actor, and
  # failing closed.
  defp current(changeset, context) do
    query = Ash.Query.lock(FieldDefinition, :for_update)

    case CMS.get_field_definition(changeset.data.id, read_opts(changeset, context, query)) do
      {:ok, field} ->
        Ash.Changeset.put_context(changeset, :section_layouts_before, placement(field))

      {:error, error} ->
        if not_found?(error) do
          Ash.Changeset.add_error(changeset, error)
        else
          Ash.Changeset.add_error(
            changeset,
            SectionLayoutNotKept.exception(section: changeset.data.section, reason: error)
          )
        end
    end
  end

  # Gone since the struct was loaded: see the moduledoc.
  defp not_found?(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp read_opts(changeset, context, query) do
    context
    |> Ash.Context.to_opts()
    |> Keyword.take([:actor, :authorize?, :tracer])
    |> Keyword.merge(
      tenant: changeset.data.org_id,
      context: FieldDefinition.all_types_context(),
      authorize_with: :error,
      query: query
    )
  end

  defp placement(field), do: Map.take(field, @placement)

  defp keep(changeset, result, context) do
    before = changeset.context.section_layouts_before
    old_owner = SectionLayouts.owner_of(before)
    old_section = before.section
    {new_owner, new_section} = after_write(changeset, before)

    cond do
      not is_binary(old_section) or is_nil(old_owner) -> {:ok, result}
      {old_owner, old_section} == {new_owner, new_section} -> {:ok, result}
      true -> sync(changeset, result, {old_owner, old_section}, {new_owner, new_section}, context)
    end
  end

  # A destroyed field leaves its section. An updated one is where it was
  # before the write, but for the columns the write set: `result` may carry
  # the stale struct's values for the columns it did not.
  defp after_write(%{action_type: :destroy}, _before), do: {nil, nil}

  defp after_write(changeset, before) do
    now = Map.merge(before, Map.take(changeset.attributes, @placement))
    {SectionLayouts.owner_of(now), now.section}
  end

  defp sync(changeset, result, {owner, old_section}, {new_owner, new_section}, context) do
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
        new_owner == owner and is_binary(new_section)

    kept =
      contained(fn ->
        with :ok <- maybe_carry(carry?, owner, old_section, new_section, opts) do
          SectionLayouts.prune(owner, [only: [old_section]] ++ opts)
        end
      end)

    case kept do
      :ok ->
        {:ok, result}

      {:error, reason} ->
        {:error, SectionLayoutNotKept.exception(section: old_section, reason: reason)}
    end
  end

  defp maybe_carry(false, _owner, _from, _to, _opts), do: :ok
  defp maybe_carry(true, owner, from, to, opts), do: SectionLayouts.carry(owner, from, to, opts)

  # A read that fails outright rolls the transaction back at once, past this
  # change: inside a nested transaction the rollback ends here instead, as
  # its error, so it can be tagged. The enclosing transaction is lost either
  # way; the tagged error rolls the field write back. `Repo.transaction/1`,
  # not `Ash.DataLayer.transaction/2`, which runs the function bare when a
  # transaction is already open.
  defp contained(fun) do
    case KilnCMS.Repo.transaction(fun) do
      {:ok, kept} -> kept
      {:error, %{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      {:error, reason} -> {:error, reason}
    end
  end
end
