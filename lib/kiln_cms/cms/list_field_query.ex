defmodule KilnCMS.CMS.ListFieldQuery do
  @moduledoc """
  The content list's custom-field conditions and field sort (#2293), turned
  into the read arguments the `CustomFieldQuery` preparation understands.

  This is the **only** place the list names `custom_filter` / `custom_sort`:
  the list holds `%{field:, op:, value:}` conditions and a `{name, dir}`
  sort, and `arguments/2` is the one function that knows how they spell as
  API arguments. When that vocabulary moves (#2292) this body is what changes.

  A condition's `op` is the list's own, per field type (`ops/1`):

  | type | ops |
  |------|-----|
  | `string`, `url` | `eq`, `contains`, `null` |
  | `text` | `contains`, `null` |
  | `integer`, `float` | `eq`, `gt`, `gte`, `lt`, `lte`, `null` |
  | `boolean` | `eq`, `null` |
  | `date` | `eq`, `gte`, `lte`, `null` |
  | `datetime` | `gte`, `lte`, `null` (whole days, inclusive) |
  | `select` | `eq`, `null` |
  | `reference`, `user`, `media` | `eq` (an id), `null` |
  | `email`, `telephone`, `slug` | `eq`, `contains`, `null` |
  | `color` | `eq`, `null` |
  | `time` | `eq`, `gte`, `lte`, `null` |

  `contains` is a case-insensitive substring match: the value is wrapped in
  `%…%` here with `\\`, `%` and `_` escaped, so `50%` finds "50%" and not
  "50 anything". `null` takes `true` (no value) or `false` (has a value).

  A value is at most `max_value_length/0` characters and is checked by
  `cast/3` against the field (an integer parses, a select value is one of its
  options unless it allows custom values, a date is ISO 8601, an id is a UUID).
  A `datetime` condition is by whole days: `gte` starts at the day's start,
  `lte` runs up to the start of the next day.

  `sortable?/1` says which fields the list can order by: a single-valued
  `string`, `text`, `integer`, `float`, `boolean`, `date`, `datetime`, `url`, `select`,
  `email`, `telephone`, `color`, `slug` or `time`. The sort is passed as `custom_sort` (`name`, or `-name` for
  descending), and rows without a value come last either way.

  The URL and saved-view spelling of these conditions (`cf`, `sort=field:…`)
  is `KilnCMSWeb.EditorLive.Filters`.
  """

  alias KilnCMS.CMS.FieldTypes

  @max_value_length 100
  @format_types [:email, :telephone, :color, :slug, :time]

  @ops %{
    string: ~w(eq contains null),
    url: ~w(eq contains null),
    text: ~w(contains null),
    integer: ~w(eq gt gte lt lte null),
    float: ~w(eq gt gte lt lte null),
    boolean: ~w(eq null),
    date: ~w(eq gte lte null),
    datetime: ~w(gte lte null),
    select: ~w(eq null),
    reference: ~w(eq null),
    user: ~w(eq null),
    media: ~w(eq null),
    email: ~w(eq contains null),
    telephone: ~w(eq contains null),
    color: ~w(eq null),
    slug: ~w(eq contains null),
    time: ~w(eq gte lte null)
  }

  # What a sort can order by one short scalar. `user` is an id, so its order
  # means nothing to an editor; the rest are refused by the preparation.
  @sortable ~w(string text integer float boolean date datetime url select email telephone color slug time)a

  @typedoc "One condition: a field name, an op from `ops/1`, a canonical value."
  @type condition :: %{field: String.t(), op: String.t(), value: String.t()}

  @typedoc "A field sort: the field name and its direction."
  @type sort :: {String.t(), :asc | :desc} | nil

  @doc "The longest value a condition holds, in characters."
  @spec max_value_length() :: pos_integer()
  def max_value_length, do: @max_value_length

  @doc "The ops a condition on a field of `field_type` may use."
  @spec ops(atom()) :: [String.t()]
  def ops(field_type), do: Map.get(@ops, field_type, [])

  @doc "Whether the list can sort by the field `definition` describes."
  @spec sortable?(map()) :: boolean()
  def sortable?(%{field_type: type} = definition),
    do: type in @sortable and Map.get(definition, :multiple) != true

  def sortable?(_definition), do: false

  @doc """
  The canonical value for `raw` as a `op` condition on `definition`, or
  `:error` when it is not a value that field can hold.
  """
  @spec cast(map(), String.t(), term()) :: {:ok, String.t()} | :error
  def cast(%{field_type: type} = definition, op, raw) when is_binary(raw) do
    raw = String.trim(raw)

    cond do
      op not in ops(type) -> :error
      raw == "" or String.length(raw) > @max_value_length -> :error
      op == "null" -> if raw in ~w(true false), do: {:ok, raw}, else: :error
      op == "contains" -> {:ok, raw}
      true -> cast_value(type, definition, raw)
    end
  end

  def cast(_definition, _op, _raw), do: :error

  defp cast_value(type, _definition, raw) when type in [:string, :text, :url],
    do: {:ok, raw}

  # A format type's own `cast/2` is the canonical spelling (a colour's case, a
  # time's padding, an email's domain), so a condition matches what is stored.
  defp cast_value(type, definition, raw) when type in @format_types do
    case FieldTypes.get(type).cast(raw, definition) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp cast_value(:integer, _definition, raw) do
    case Integer.parse(raw) do
      {integer, ""} -> {:ok, Integer.to_string(integer)}
      _ -> :error
    end
  end

  defp cast_value(:float, _definition, raw) do
    case Kiln.FieldType.parse_float(raw) do
      {float, ""} -> {:ok, Float.to_string(float)}
      _ -> :error
    end
  end

  defp cast_value(:boolean, _definition, raw),
    do: if(raw in ~w(true false), do: {:ok, raw}, else: :error)

  defp cast_value(type, _definition, raw) when type in [:date, :datetime] do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> :error
    end
  end

  defp cast_value(:select, definition, raw) do
    if raw in List.wrap(Map.get(definition, :options)) or
         Map.get(definition, :allow_custom) == true,
       do: {:ok, raw},
       else: :error
  end

  defp cast_value(type, _definition, raw) when type in [:reference, :user, :media] do
    case Ecto.UUID.cast(raw) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  @doc """
  The read arguments for `conditions` and `sort`: a map holding
  `:custom_filter` and/or `:custom_sort`, and nothing for what is empty, so a
  list with neither passes no arguments at all. `definitions` are the field
  definitions the conditions were validated against (a condition's type picks
  how its value is spelled).
  """
  @spec arguments([condition()], sort(), [map()]) :: map()
  def arguments(conditions, sort, definitions) do
    types = Map.new(definitions, &{&1.name, &1.field_type})

    %{}
    |> put_filter(conditions, types)
    |> put_sort(sort)
  end

  defp put_filter(args, [], _types), do: args

  defp put_filter(args, conditions, types) do
    filter =
      Enum.reduce(conditions, %{}, fn %{field: field, op: op, value: value}, acc ->
        Enum.reduce(spell(Map.get(types, field), op, value), acc, fn {api_op, api_value}, acc ->
          Map.update(acc, field, %{api_op => api_value}, &Map.put(&1, api_op, api_value))
        end)
      end)

    Map.put(args, :custom_filter, filter)
  end

  defp put_sort(args, nil), do: args
  defp put_sort(args, {name, :asc}), do: Map.put(args, :custom_sort, name)
  defp put_sort(args, {name, :desc}), do: Map.put(args, :custom_sort, "-" <> name)

  # A datetime is stored offset-less and the list asks by whole days: from the
  # start of the first day, up to (not including) the start of the day after
  # the last.
  defp spell(:datetime, "gte", date), do: [{"gte", day_start(date)}]

  defp spell(:datetime, "lte", date),
    do: [{"lt", date |> Date.from_iso8601!() |> Date.add(1) |> day_start()}]

  defp spell(_type, "contains", text), do: [{"ilike", "%" <> escape_like(text) <> "%"}]
  defp spell(_type, op, value), do: [{op, value}]

  defp day_start(%Date{} = date), do: day_start(Date.to_iso8601(date))
  defp day_start(iso), do: iso <> "T00:00:00"

  defp escape_like(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")
end
