defmodule KilnCMS.CMS.Validations.SafetyFieldsShape do
  @moduledoc """
  `SiteSafetyFields.fields` must be a map of content-type name to a list of
  field names (`"*"` meaning every editorial field), within the given bounds.
  A malformed value would otherwise be read on every live edit and either crash
  the diff or silently list nothing.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :fields) do
      fields when is_map(fields) -> check(fields, opts)
      _other -> invalid("must be a map of content type name to a list of field names")
    end
  end

  defp check(fields, opts) do
    max_types = Keyword.fetch!(opts, :max_types)
    max_fields = Keyword.fetch!(opts, :max_fields)

    cond do
      map_size(fields) > max_types ->
        invalid("lists more than #{max_types} content types")

      not Enum.all?(fields, &entry_ok?(&1, max_fields)) ->
        invalid("must map each content type name to a list of up to #{max_fields} field names")

      true ->
        :ok
    end
  end

  defp entry_ok?({type, names}, max_fields) do
    name_ok?(type) and is_list(names) and length(names) <= max_fields and
      Enum.all?(names, &name_ok?/1)
  end

  defp name_ok?(name),
    do: is_binary(name) and name != "" and String.length(name) <= KilnCMS.Limits.line()

  defp invalid(message),
    do: {:error, InvalidAttribute.exception(field: :fields, message: message)}
end
