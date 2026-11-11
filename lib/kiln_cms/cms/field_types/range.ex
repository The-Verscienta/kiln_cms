defmodule KilnCMS.CMS.FieldTypes.Range do
  @moduledoc """
  A **range** custom field (#2278): a span between two bounds, stored as
  `%{"min" => x, "max" => y}`. For a price band, an age bracket, opening
  months or a date window.

  The bounds are either both **numbers** or both **dates** (`YYYY-MM-DD`);
  the kind is read from the values, so no option is needed. At least one bound
  is required (a half-open range is a value), and when both are given `min`
  may not exceed `max`. A key left out is simply not stored.

  Accepted input is the editor's part map (`min`/`max` as text), or a map from
  an API client with atom or string keys. A numeric string becomes a number
  (`"5"` is the integer 5, `"5.5"` the float 5.5); integers stay integers and
  floats stay floats. Numbers are bounded to what JavaScript reads exactly
  (±9,007,199,254,740,991), and `NaN`, `Infinity` and a date-time are refused.
  A mix of a number and a date is refused.

  The JSON Schema (`json_schema/1`) states the value twice (#2548). The merged
  object lets each bound be a number or a date, which is what a generator that
  only reads `type`/`properties` (Swift, Kotlin, an older `kiln-types`)
  declares. A sibling `anyOf` narrows it to what `cast/2` accepts: two number
  bounds or two date bounds, at least one present, or `null`. A validator
  checks both, so a number with a date is refused by the schema as on write,
  and the TypeScript emitters render the `anyOf` as a union of the two shapes.
  The `anyOf` is added beside the merged object rather than replacing it with
  a `oneOf`, because published generators read every `oneOf` member as a
  `$ref`.

  Ranges are not filterable (other than for presence) or sortable, and are
  served through GraphQL as the generic JSON value. They are never indexed for
  search, even when flagged `searchable`: a bound is a number or a date, not
  prose.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_int 9_007_199_254_740_991
  @max_text 64

  @impl Kiln.FieldType
  def label, do: "Range"

  @impl Kiln.FieldType
  def description do
    gettext(
      "A span between two numbers or two dates, with either end optional. For a price band, an age bracket or a date window. Cannot be filtered or sorted."
    )
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :json

  @impl Kiln.FieldType
  def json_schema(_definition) do
    bound = %{
      "type" => ["number", "string"],
      "description" =>
        "A number, or an ISO-8601 date (YYYY-MM-DD); both bounds are the same kind."
    }

    %{
      "type" => ["object", "null"],
      "properties" => %{"min" => bound, "max" => bound},
      "additionalProperties" => false,
      "anyOf" => [
        bounds(%{"type" => "number"}),
        bounds(%{"type" => "string", "format" => "date"}),
        %{"type" => "null"}
      ]
    }
  end

  # One kind of range: both bounds of `bound`'s type, either optional but not
  # both, since `cast/2` refuses an empty range.
  defp bounds(bound) do
    %{
      "type" => "object",
      "properties" => %{"min" => bound, "max" => bound},
      "additionalProperties" => false,
      "minProperties" => 1
    }
  end

  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{
        key: "min",
        label: gettext("From"),
        type: "text",
        required?: false,
        help: gettext("A number or a date (YYYY-MM-DD)."),
        attrs: %{placeholder: "10 / 2026-01-31", autocomplete: "off"}
      },
      %{
        key: "max",
        label: gettext("To"),
        type: "text",
        required?: false,
        help: gettext("The same kind as From: two numbers or two dates."),
        attrs: %{placeholder: "20 / 2026-12-31", autocomplete: "off"}
      }
    ]
  end

  @impl Kiln.FieldType
  def cast(value, _definition) when is_map(value) and not is_struct(value) do
    with {:ok, parts} <- parts(value),
         {:ok, min} <- bound(Map.get(parts, "min"), "from"),
         {:ok, max} <- bound(Map.get(parts, "max"), "to") do
      assemble(min, max)
    end
  end

  def cast(_value, _definition),
    do: {:error, "must be a range with a \"min\" and/or a \"max\""}

  defp parts(map) do
    parts = Map.new(map, fn {key, value} -> {key_name(key), value} end)

    if Map.keys(parts) -- ["min", "max"] == [],
      do: {:ok, parts},
      else: {:error, "may only have \"min\" and \"max\""}
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(_key), do: :invalid

  # `nil` and blank text are "no bound".
  defp bound(nil, _name), do: {:ok, nil}
  defp bound(value, _name) when is_boolean(value), do: bad_bound()

  defp bound(value, name) when is_integer(value),
    do: if(abs(value) <= @max_int, do: {:ok, {:number, value}}, else: too_large(name))

  defp bound(value, name) when is_float(value),
    do: if(abs(value) <= @max_int, do: {:ok, {:number, value}}, else: too_large(name))

  defp bound(%Date{} = date, _name), do: {:ok, {:date, Date.to_iso8601(date)}}

  defp bound(value, name) when is_binary(value) do
    text = String.trim(value)

    cond do
      text == "" -> {:ok, nil}
      byte_size(text) > @max_text -> bad_bound()
      true -> text |> parse_number() |> text_bound(text, name)
    end
  end

  defp bound(_value, _name), do: bad_bound()

  defp text_bound({:ok, number}, _text, name),
    do: bound(number, name)

  defp text_bound(:error, text, _name) do
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, text) do
      case Date.from_iso8601(text) do
        {:ok, date} -> {:ok, {:date, Date.to_iso8601(date)}}
        {:error, _} -> bad_bound()
      end
    else
      bad_bound()
    end
  end

  # Whole-string decimal numbers only: `Integer.parse/1` and `Float.parse/1`
  # leave a remainder for `1_000`, `5abc`, a date or `Infinity`, which is
  # refused here. `Float.parse/1` accepts neither `NaN` nor `Infinity`, and
  # answers `:error` for an exponent past the float range.
  defp parse_number(text) do
    case Integer.parse(text) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(text) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp bad_bound, do: {:error, "bounds must both be numbers or both be dates (YYYY-MM-DD)"}
  defp too_large(name), do: {:error, "the #{name} bound is too large"}

  defp assemble(nil, nil), do: {:error, "needs a minimum, a maximum, or both"}

  defp assemble(min, max) do
    bounds = for {key, {kind, value}} <- [{"min", min}, {"max", max}], do: {key, kind, value}

    case bounds |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [_one_kind] ->
        range = Map.new(bounds, fn {key, _kind, value} -> {key, value} end)

        if ordered?(range),
          do: {:ok, range},
          else: {:error, "the minimum must not be greater than the maximum"}

      _mixed ->
        {:error, "bounds must both be numbers or both be dates (YYYY-MM-DD)"}
    end
  end

  # ISO dates order as text.
  defp ordered?(%{"min" => min, "max" => max}), do: min <= max
  defp ordered?(_open), do: true
end
