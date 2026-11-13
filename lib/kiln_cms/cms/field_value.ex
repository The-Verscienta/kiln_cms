defmodule KilnCMS.CMS.FieldValue do
  @moduledoc """
  One custom field value coerced to what a write stores, by field type: the
  coercion `KilnCMS.CMS.Changes.ApplyCustomFields` applies to every scalar
  value (a top-level field, an item of a typed list, a group sub-field, a
  reference's link value), shared with filter operands so a filter compares
  what a write would have stored.

  Pure: no database, no tenant. The record-resolving types (`:media`,
  `:reference`, `:user`) and the list shapes stay `ApplyCustomFields`' own.
  """

  alias KilnCMS.CMS.FieldDefinition

  @not_single "must be a single value, not an object or a list"

  @doc """
  The message for an object or a list where a field takes one value, as it
  completes "<Label> (<name>) …".
  """
  @spec not_single() :: String.t()
  def not_single, do: @not_single

  @doc """
  `value` coerced for the single (not `multiple`) field `definition`:
  `{:ok, json_native}` or `{:error, message}`, the message completing
  "<Label> (<name>) …".
  """
  @spec coerce(term(), map()) :: {:ok, term()} | {:error, String.t()}
  def coerce(value, definition)

  # A rich `:text` field (the default `format`) is HTML the TipTap field
  # editor wrote, or an importer did: sanitized to the rich-text block's
  # allow-list (`KilnCMS.CMS.TextFormat`), so the field is no wider a hole
  # than a block. A plain one is stored as typed.
  def coerce(value, %{field_type: :text} = def) do
    text = value |> to_string() |> String.trim()

    if Map.get(def, :format, :rich) == :rich,
      do: {:ok, KilnCMS.CMS.TextFormat.sanitize(text)},
      else: {:ok, text}
  end

  def coerce(value, %{field_type: type}) when type in [:string, :url] do
    {:ok, value |> to_string() |> String.trim()}
  end

  # A write may name an option by its label (`option_labels`); the value is
  # what is stored.
  def coerce(value, %{field_type: :select, options: options} = def) do
    str = FieldDefinition.option_value(def, value |> to_string() |> String.trim())
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end

  def coerce(value, %{field_type: :integer}) do
    case value do
      v when is_integer(v) -> {:ok, v}
      v -> parse(Integer, v, "must be a whole number")
    end
  end

  def coerce(value, %{field_type: :float}) do
    case value do
      v when is_number(v) -> {:ok, v / 1}
      v -> parse(Float, v, "must be a number")
    end
  end

  def coerce(value, %{field_type: :boolean}) do
    case value do
      v when is_boolean(v) -> {:ok, v}
      v when v in ["true", "1", "on"] -> {:ok, true}
      v when v in ["false", "0", "off", ""] -> {:ok, false}
      _ -> {:error, "must be a boolean"}
    end
  end

  def coerce(value, %{field_type: :date}) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "must be a date (YYYY-MM-DD)"}
    end
  end

  def coerce(value, %{field_type: :datetime}) do
    str = to_string(value)

    # Accept both full ISO-8601 and the HTML datetime-local shape (no seconds /
    # no offset), normalizing to an ISO-8601 string.
    with {:error, _} <- parse_datetime(str),
         {:error, _} <- parse_datetime(str <> ":00") do
      {:error, "must be a date and time"}
    end
  end

  # A plugin-contributed field type (`Kiln.FieldType`): the plugin's `cast/2`
  # owns coercion + validation. The contract requires a JSON-native return —
  # anything else is a loud contract violation, not a swallowed write.
  def coerce(value, %{field_type: type} = definition) do
    case KilnCMS.CMS.FieldTypes.get(type) do
      nil ->
        {:error, "has an unregistered field type"}

      module ->
        case module.cast(value, definition) do
          {:ok, cast} ->
            {:ok, cast}

          {:error, message} when is_binary(message) ->
            {:error, message}

          other ->
            raise "#{inspect(module)}.cast/2 must return {:ok, value} | {:error, message}, " <>
                    "got: #{inspect(other)}"
        end
    end
  end

  defp parse_datetime(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> {:ok, NaiveDateTime.to_iso8601(ndt)}
      error -> error
    end
  end

  defp parse(mod, value, message) do
    case mod.parse(to_string(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, message}
    end
  end
end
