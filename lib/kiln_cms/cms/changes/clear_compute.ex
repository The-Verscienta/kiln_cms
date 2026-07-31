defmodule KilnCMS.CMS.Changes.ClearCompute do
  @moduledoc """
  Nils a `FieldDefinition`'s `compute` formula whenever its type is not
  `:computed` (#429).

  The fields admin renders the formula input only for `:computed`, so switching
  an existing computed field to another type submits no `compute` param at all.
  Without this, `Ash.Changeset.get_attribute/2` keeps returning the *stored*
  formula, and the definition carries a dangling formula for a type that can
  never evaluate it — visible in the admin list and meaningless everywhere else.

  Clearing it here rather than rejecting it in a validation is deliberate: an
  error would attach to a field the form no longer renders, leaving the admin
  no way to save and no way to see why.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :computed do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :compute, nil)
    end
  end
end
