defmodule KilnCMS.CMS.Validations.DefaultSource do
  @moduledoc """
  A `:copy_of` dynamic default (#2286) must name a field it can copy:

    * a sibling in the same scope (the same content type or dynamic type);
    * not the field itself, and not a field that itself copies (one hop, so
      there is no loop to detect);
    * of the same type, and a plain single-valued one
      (`KilnCMS.CMS.DynamicDefaults.copy_types/0`);
    * not private unless this field is too — nothing copies a private value
      somewhere public.

  Every other source needs nothing here: `Changes.ClearDefaultSource` drops one
  the field's type cannot take.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.DynamicDefaults
  alias KilnCMS.CMS.Validations.FieldCondition

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :default_source) == :copy_of do
      check(changeset, Ash.Changeset.get_attribute(changeset, :default_field))
    else
      :ok
    end
  end

  defp check(_changeset, source) when source in [nil, ""],
    do: error(gettext("needs the field to copy"))

  defp check(changeset, source) do
    self = Ash.Changeset.get_attribute(changeset, :name)

    if source == self do
      error(gettext("can't copy the field itself"))
    else
      target =
        changeset
        |> FieldCondition.siblings(changeset.to_tenant)
        |> Enum.find(&(&1.name == source))

      problem(changeset, source, target)
    end
  end

  defp problem(_changeset, source, nil),
    do: error(gettext("%{field} is not a field beside this one", field: source))

  defp problem(changeset, source, target) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)
    private? = Ash.Changeset.get_attribute(changeset, :private) == true

    cond do
      target.field_type != type or target.multiple ->
        error(gettext("%{field} is not a single %{type} field", field: source, type: type))

      target.field_type not in DynamicDefaults.copy_types() ->
        error(gettext("%{field} has no simple value to copy", field: source))

      DynamicDefaults.dynamic?(target) and target.default_source == :copy_of ->
        error(gettext("%{field} itself copies another field", field: source))

      target.private and not private? ->
        error(gettext("%{field} is private; a public field can't copy it", field: source))

      true ->
        :ok
    end
  end

  defp error(message),
    do: {:error, InvalidAttribute.exception(field: :default_field, message: message)}
end
