defmodule KilnCMS.CMS.Validations.TitleTemplate do
  @moduledoc """
  Rejects a `title_template` (#2287) that does not parse, reads `title` or
  `slug` (a cycle), or — on an existing type — reads a field the type does not
  define or one that is private. See `KilnCMS.CMS.Titles` for the rules.

  The field checks run on **update** only, when the template is changing. A new
  type has no fields yet, so every reference would read as unknown; and a
  field sync import (`KilnCMS.CMS.FieldSync`) creates the type before its
  fields. The cost is that a template saved on create can name a field that
  never appears, which evaluates blank — and a private field is dropped from
  the context before evaluation, so it can never reach a title.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.Titles
  alias KilnCMS.CMS.Validations.Lookup

  @impl true
  def validate(changeset, _opts, context) do
    template = Ash.Changeset.get_attribute(changeset, :title_template)

    case Titles.validate(template, definitions_opts(changeset, context, template)) do
      :ok -> :ok
      {:error, message} -> {:error, field: :title_template, message: message}
    end
  end

  defp definitions_opts(changeset, context, template) do
    id = Ash.Changeset.get_data(changeset, :id)

    if is_binary(template) and not is_nil(id) and
         Ash.Changeset.changing_attribute?(changeset, :title_template) do
      # As the caller, failing closed (#1659): an admin reads every field
      # definition, and a refused read must not pass a bad reference off as
      # "no fields" — it raises.
      [
        definitions:
          KilnCMS.CMS.field_definitions_for_definition!(
            id,
            Lookup.as_caller(context, changeset.to_tenant)
          )
      ]
    else
      []
    end
  end
end
