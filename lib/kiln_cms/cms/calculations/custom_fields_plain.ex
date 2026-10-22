defmodule KilnCMS.CMS.Calculations.CustomFieldsPlain do
  @moduledoc """
  The `custom_fields_plain` calculation on every content type: the plain-text
  rendition of the record's `deliver_plain` `:text` fields
  (`KilnCMS.CMS.PlainFields`), or `nil` when its type flags none.

  JSON:API (`fields[page]=title,custom_fields,custom_fields_plain`) and
  GraphQL (`customFieldsPlain`) clients ask for it, as for
  `inherited_fields`: neither serves it by default, so a response that does
  not ask is byte-identical to what it was. It reads the stored
  `custom_fields` the row reports beside it, against the type's current
  definitions — one definitions read per type in the batch.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.PlainFields

  @impl true
  def load(query, _opts, _context) do
    Enum.filter(
      [:org_id, :custom_fields, :type_definition_id],
      &Ash.Resource.Info.attribute(query.resource, &1)
    )
  end

  @impl true
  def calculate(records, _opts, _context) do
    definitions =
      records
      |> Enum.map(&scope/1)
      |> Enum.uniq()
      |> Map.new(fn {resource, type_definition_id, org_id} = scope ->
        {scope, ApplyCustomFields.definitions(resource, type_definition_id, org_id)}
      end)

    Enum.map(records, fn record ->
      PlainFields.project(Map.get(record, :custom_fields), Map.fetch!(definitions, scope(record)))
    end)
  end

  defp scope(%resource{} = record),
    do: {resource, Map.get(record, :type_definition_id), Map.get(record, :org_id)}
end
