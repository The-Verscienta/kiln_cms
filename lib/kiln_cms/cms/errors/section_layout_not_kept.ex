defmodule KilnCMS.CMS.Errors.SectionLayoutNotKept do
  @moduledoc """
  A field definition write refused because the section layouts it affects
  (`KilnCMS.CMS.FieldSection`) could not be kept in step with it: carrying a
  layout to a renamed section, or pruning the layout of a section the write
  left without fields, was refused (`KilnCMS.CMS.Changes.KeepSectionLayouts`).

  The field write rolls back with it, so no layout is left behind with no
  field to lay out. Its own type so the fields admin can say the section
  layout was the problem; `reason` is the refused read or write.
  """
  use Splode.Error, fields: [:section, :reason], class: :invalid

  @impl true
  def message(%{section: section, reason: reason}) do
    "the layout of section #{inspect(section)} could not be kept in step with this field: " <>
      describe(reason)
  end

  defp describe(%{__exception__: true} = reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)
end
