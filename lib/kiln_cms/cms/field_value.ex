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

  # The core types `coerce/2` reads as one value. A plugin type's (and a
  # built-in `Kiln.FieldType`'s) `cast/2` decides for itself: a composite
  # such as a geolocation or a range takes an object.
  @single_types [:text, :string, :url, :select, :integer, :float, :boolean, :date, :datetime]

  # The types whose stored text is a tidied form of what was sent (#2677): a
  # trimmed string or address, a select option by its label, and the built-in
  # format types' canonical spellings. Not `:text` (sanitizing HTML per operand
  # is not a comparison), not the date-times (#2678), and not a plugin type,
  # whose `cast/2` the `Kiln.FieldType` contract does not promise to be
  # deterministic: its operands are compared as the text sent.
  @canonical_types [:string, :url, :select, :email, :color, :telephone, :time, :slug]

  @doc """
  The message for an object or a list where a field takes one value, as it
  completes "<Label> (<name>) …".
  """
  @spec not_single() :: String.t()
  def not_single, do: @not_single

  @doc """
  `term` as the text a field stores or compares (#2743): `{:ok, text}`, or
  `:error` for a value that is not one value — a plain map (a nested object,
  a locale map), a list, or a struct with no text form. Anything else is
  `to_string/1`'s: a number, a boolean or an atom as its text, a `Date` or
  `Decimal` as its own.
  """
  @spec text(term()) :: {:ok, String.t()} | :error
  def text(term) when is_list(term), do: :error
  def text(term) when is_map(term) and not is_struct(term), do: :error

  def text(term) do
    if String.Chars.impl_for(term), do: {:ok, to_string(term)}, else: :error
  end

  @doc """
  What a filter operand `raw` on the single field `definition` is compared as
  besides itself (#2677): the value a write would have stored for it —
  `{:ok, "#ffffff"}` for a color's `"#FFF"`, the option's value for a
  select's label — or `:none` when the type keeps operands as sent, or the
  field could never hold `raw` (it then simply matches nothing).
  """
  @spec canonical(map(), term()) :: {:ok, String.t() | number()} | :none
  def canonical(%{field_type: type} = definition, raw)
      when type in @canonical_types and (is_binary(raw) or is_number(raw)) do
    case coerce(raw, Map.put(definition, :multiple, false)) do
      {:ok, value} when is_binary(value) or is_number(value) -> {:ok, value}
      _refused -> :none
    end
  end

  def canonical(_definition, _raw), do: :none

  @doc """
  `value` coerced for the single (not `multiple`) field `definition`:
  `{:ok, json_native}` or `{:error, message}`, the message completing
  "<Label> (<name>) …".
  """
  @spec coerce(term(), map()) :: {:ok, term()} | {:error, String.t()}
  def coerce(value, definition)

  # An object or a list where the field holds one value (#2743): a locale map
  # sent to a field that is not localized, a nested filter shape, an array.
  # Refused here rather than stringified (a raise for a map, `["a", "b"]`
  # joined into `"ab"` for a list). Not a struct: a `%Date{}` is one value.
  def coerce(value, %{field_type: type})
      when type in @single_types and
             (is_list(value) or (is_map(value) and not is_struct(value))),
      do: {:error, @not_single}

  # A rich `:text` field (the default `format`) is HTML the TipTap field
  # editor wrote, or an importer did: sanitized to the rich-text block's
  # allow-list (`KilnCMS.CMS.TextFormat`), so the field is no wider a hole
  # than a block. A plain one is stored as typed.
  def coerce(value, %{field_type: :text} = def) do
    with {:ok, text} <- single_text(value) do
      text = String.trim(text)

      if Map.get(def, :format, :rich) == :rich,
        do: {:ok, KilnCMS.CMS.TextFormat.sanitize(text)},
        else: {:ok, text}
    end
  end

  def coerce(value, %{field_type: type}) when type in [:string, :url] do
    with {:ok, text} <- single_text(value), do: {:ok, String.trim(text)}
  end

  # A write may name an option by its label (`option_labels`); the value is
  # what is stored.
  def coerce(value, %{field_type: :select, options: options} = def) do
    with {:ok, text} <- single_text(value) do
      str = FieldDefinition.option_value(def, String.trim(text))
      if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
    end
  end

  def coerce(value, %{field_type: :integer}) do
    case value do
      v when is_integer(v) -> {:ok, v}
      v -> parse(&Integer.parse/1, v, "must be a whole number")
    end
  end

  def coerce(value, %{field_type: :float}) do
    case value do
      v when is_number(v) -> {:ok, v / 1}
      v -> parse(&Kiln.FieldType.parse_float/1, v, "must be a number")
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
    with {:ok, text} <- single_text(value) do
      case Date.from_iso8601(text) do
        {:ok, date} -> {:ok, Date.to_iso8601(date)}
        _ -> {:error, "must be a date (YYYY-MM-DD)"}
      end
    end
  end

  def coerce(value, %{field_type: :datetime}) do
    # Accept both full ISO-8601 and the HTML datetime-local shape (no seconds /
    # no offset), normalizing to an ISO-8601 string.
    with {:ok, str} <- single_text(value),
         {:error, _} <- parse_datetime(str),
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

  # `Kiln.FieldType.parse_float/1` for a float: `Float.parse/1` raises on an
  # overflow literal under Elixir 1.19, and this text comes from the caller.
  defp parse(parser, value, message) do
    with {:ok, text} <- single_text(value) do
      case parser.(text) do
        {parsed, ""} -> {:ok, parsed}
        _ -> {:error, message}
      end
    end
  end

  defp single_text(value) do
    case text(value) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, @not_single}
    end
  end
end
