defmodule KilnCMS.CMS.Changes.ClearDeliverLlm do
  @moduledoc """
  Clears a `FieldDefinition`'s `deliver_llm` flag (#2282) unless the field is
  a **top-level** `:string`, `:text`, `:flexible` or `:group` field.

  The fields admin shows the option only for those, so retyping a field
  submits no `deliver_llm` param and a stored `true` would linger on a field
  the `:llm` and `:json_ld` artifacts never project
  (`KilnCMS.Firing.AnswerText`). A sub-field, a link field or an item type
  is cleared too: the flag lives on the container that owns the text.
  """
  use Ash.Resource.Change

  @types [:string, :text, :flexible, :group]

  @doc "The field types that may carry `deliver_llm`."
  @spec types() :: [atom()]
  def types, do: @types

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) in @types and
         KilnCMS.CMS.FieldDefinition.top_level?(changeset) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :deliver_llm, false)
    end
  end
end
