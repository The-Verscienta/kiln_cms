defmodule KilnCMS.CMS.Changes.ClearDefaultSource do
  @moduledoc """
  Keeps a `FieldDefinition`'s dynamic default (#2286) consistent, by clearing
  rather than rejecting — the same stance as `ClearCompute`: an error would
  land on a control the form no longer renders.

    * a `default_source` the field's type cannot take (retyped, or a link or
      group sub-field) is dropped (`KilnCMS.CMS.DynamicDefaults.sources_for/1`);
    * a `multiple` field keeps none (a list is not a single copied value);
    * a field with a source has no static `default` — the source replaces it;
    * `default_field` only means something for `:copy_of`.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.DynamicDefaults

  @impl true
  def change(changeset, _opts, _context) do
    source = Ash.Changeset.get_attribute(changeset, :default_source)
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    source = if usable?(changeset, source, type), do: source, else: nil

    changeset
    |> Ash.Changeset.force_change_attribute(:default_source, source)
    |> clear_field(source)
    |> clear_static(source)
  end

  defp usable?(_changeset, nil, _type), do: false

  defp usable?(changeset, source, type) do
    source in DynamicDefaults.sources_for(type) and
      not Ash.Changeset.get_attribute(changeset, :multiple) and
      is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) and
      is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id))
  end

  defp clear_field(changeset, :copy_of), do: changeset

  defp clear_field(changeset, _source),
    do: Ash.Changeset.force_change_attribute(changeset, :default_field, nil)

  defp clear_static(changeset, nil), do: changeset

  defp clear_static(changeset, _source),
    do: Ash.Changeset.force_change_attribute(changeset, :default, nil)
end
