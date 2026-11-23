defmodule KilnCMS.CMS.Changes.ClearReferenceOptions do
  @moduledoc """
  Resets a `FieldDefinition`'s target-side options — `max_sources` (R1b),
  `on_target_delete` (R5), `schema_org_property` (#2044), `selection`
  (#2285) and `edit_inline` (#2283) — whenever the field is not a `:reference`. On a reference it
  normalizes `selection` to string keys (an empty one is nil) and stores an
  unticked `edit_inline` as nil.

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin
  shows those controls only for a reference, so retyping one to another type
  submits neither, and a stored cap or delete rule would otherwise linger on a
  field that has no targets to apply it to. A link field (R3) is never a
  reference, so it is cleared too.

  A reference that is not top-level (#2282: a sub-field of an item type or a
  group) is cleared the same way, though it is a reference: its connections
  live inside a row, not in a record-level field, so a cap (`max_sources`), a
  delete rule (`on_target_delete`), a schema.org property and a `selection`
  would each claim something nothing honors. Item references behave as
  `on_target_delete: :keep` and are uncapped. `edit_inline` is the exception:
  it is left set so `Validations.ReferenceEditInline` refuses it with its own
  message (#2283).
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ReferenceSelection

  @impl true
  def change(changeset, _opts, _context) do
    reference? = Ash.Changeset.get_attribute(changeset, :field_type) == :reference

    cond do
      reference? and KilnCMS.CMS.FieldDefinition.top_level?(changeset) ->
        changeset |> normalize_selection() |> normalize_edit_inline()

      # Not top-level: the target-side options are cleared, but `edit_inline`
      # is left for `Validations.ReferenceEditInline` to refuse (#2283), as it
      # does for any reference that is not a field of the record itself.
      reference? ->
        clear_target_options(changeset)

      true ->
        changeset
        |> clear_target_options()
        |> Ash.Changeset.force_change_attribute(:edit_inline, nil)
    end
  end

  defp clear_target_options(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:max_sources, nil)
    |> Ash.Changeset.force_change_attribute(:on_target_delete, :keep)
    |> Ash.Changeset.force_change_attribute(:schema_org_property, nil)
    |> Ash.Changeset.force_change_attribute(:selection, nil)
  end

  # Off is nil, whichever way the form said it ("false" or absent).
  defp normalize_edit_inline(changeset) do
    case Ash.Changeset.fetch_change(changeset, :edit_inline) do
      {:ok, false} -> Ash.Changeset.force_change_attribute(changeset, :edit_inline, nil)
      _other -> changeset
    end
  end

  defp normalize_selection(changeset) do
    case Ash.Changeset.fetch_change(changeset, :selection) do
      {:ok, selection} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :selection,
          ReferenceSelection.normalize(selection)
        )

      :error ->
        changeset
    end
  end
end
