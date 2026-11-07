defmodule KilnCMS.CMS.Conditions do
  @moduledoc """
  Conditional rules for custom fields (#2277): a `FieldDefinition` may carry a
  `visible_when` rule (the field is hidden while it is false) and a
  `required_when` rule (the field is required while it is true).

  A rule is plain JSON, so it round-trips through jsonb, the APIs and the
  editor's JavaScript evaluator (`assets/js/conditions.js`), which mirrors
  this module. Both are tested against one shared fixture,
  `test/support/fixtures/conditions_cases.json`.

      %{"field" => "kind", "op" => "eq", "value" => "other"}
      %{"all" => [leaf, leaf]}
      %{"any" => [leaf, %{"all" => [leaf, leaf]}]}

  ## Operators

    * `eq` / `neq` — the field's value equals `value` (numbers compare as
      numbers, so `5` equals `"5"`). A multi-value field (a list) *contains*
      it;
    * `in` — `value` is a list; the field's value is one of them (a list
      overlaps it);
    * `empty` / `not_empty` — no `value`;
    * `gt` / `lt` — numeric, or ISO-8601 date / datetime, comparison. False
      when either side cannot be read as one.

  ## Emptiness

  A value is **empty** when it is missing, `nil`, `""`, only whitespace, an
  empty list, or a list of nothing but empty values (a multi-select posts a
  leading `""`). `false` is a value: an unchecked boolean is not empty. A rule
  naming a field the values do not hold sees it as empty, and evaluation never
  raises — a rule that cannot be read is false.

  ## Limits

  A rule nests at most 3 levels deep and holds at most 10 nodes (leaves and
  combinators), and an `in` list at most 50 values.
  """

  @ops ~w(eq neq in empty not_empty gt lt)
  @value_ops ~w(eq neq gt lt)
  @max_depth 3
  @max_nodes 10
  @max_in 50

  @type rule :: map()
  @type scope :: %{optional(String.t()) => term()}

  @doc "The operators a leaf may use."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc "The operators that compare magnitude, valid on numeric and date fields only."
  @spec ordering_ops() :: [String.t()]
  def ordering_ops, do: ~w(gt lt)

  @doc """
  A rule with string keys and string operators throughout, or `nil` for no
  rule (`nil`, or an empty map). Anything else comes back keyed as given, so
  `check_shape/1` can name what is wrong with it.
  """
  @spec normalize(term()) :: rule() | nil
  def normalize(nil), do: nil
  def normalize(rule) when is_map(rule) and map_size(rule) == 0, do: nil
  def normalize(rule), do: stringify(rule)

  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp stringify(value), do: value

  @doc "Whether `rule` (normalized or not) has a valid shape."
  @spec valid_shape?(term()) :: boolean()
  def valid_shape?(rule), do: check_shape(rule) == :ok

  @doc """
  `:ok`, or `{:error, reason}` with a short English reason naming the first
  thing wrong with the rule's shape. The reason is for the admin; callers
  wrap it in their own gettext.
  """
  @spec check_shape(term()) :: :ok | {:error, String.t()}
  def check_shape(rule) do
    case normalize(rule) do
      nil ->
        {:error, "is empty"}

      rule ->
        rule |> shape(1) |> within_node_cap()
    end
  end

  defp within_node_cap({:ok, nodes}) when nodes > @max_nodes,
    do: {:error, "has more than #{@max_nodes} conditions"}

  defp within_node_cap({:ok, _nodes}), do: :ok
  defp within_node_cap(error), do: error

  defp shape(_rule, depth) when depth > @max_depth,
    do: {:error, "nests more than #{@max_depth} levels"}

  defp shape(%{"all" => children} = rule, depth), do: combinator(rule, children, depth)
  defp shape(%{"any" => children} = rule, depth), do: combinator(rule, children, depth)

  defp shape(%{"field" => field, "op" => op} = leaf, _depth) do
    extra = Map.keys(leaf) -- ["field", "op", "value"]

    cond do
      extra != [] -> {:error, "has an unknown key #{inspect(hd(extra))}"}
      not (is_binary(field) and field != "") -> {:error, "names no field"}
      op not in @ops -> {:error, "has an unknown operator #{inspect(op)}"}
      true -> leaf_value(op, Map.get(leaf, "value"))
    end
  end

  defp shape(_rule, _depth), do: {:error, "is not a condition"}

  defp combinator(rule, children, depth) do
    cond do
      map_size(rule) != 1 ->
        {:error, "mixes all/any with other keys"}

      not (is_list(children) and children != []) ->
        {:error, "has an empty all/any group"}

      true ->
        Enum.reduce_while(children, {:ok, 1}, &child_shape(&1, &2, depth + 1))
    end
  end

  defp child_shape(child, {:ok, count}, depth) do
    case shape(child, depth) do
      {:ok, n} -> {:cont, {:ok, count + n}}
      error -> {:halt, error}
    end
  end

  defp leaf_value(op, value) when op in @value_ops do
    if scalar?(value), do: {:ok, 1}, else: {:error, "needs a single value for #{op}"}
  end

  defp leaf_value("in", value) do
    if is_list(value) and value != [] and length(value) <= @max_in and
         Enum.all?(value, &scalar?/1),
       do: {:ok, 1},
       else: {:error, "needs a list of 1 to #{@max_in} values for in"}
  end

  defp leaf_value(op, nil) when op in ["empty", "not_empty"], do: {:ok, 1}
  defp leaf_value(op, _value), do: {:error, "takes no value for #{op}"}

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  @doc "The field names a rule reads, in order of first use."
  @spec references(term()) :: [String.t()]
  def references(rule) do
    rule |> normalize() |> collect() |> Enum.uniq()
  end

  defp collect(%{"all" => children}) when is_list(children),
    do: Enum.flat_map(children, &collect/1)

  defp collect(%{"any" => children}) when is_list(children),
    do: Enum.flat_map(children, &collect/1)

  defp collect(%{"field" => field}) when is_binary(field), do: [field]
  defp collect(_other), do: []

  @doc "Each `{field, op}` pair a rule tests, in order."
  @spec leaves(term()) :: [{String.t(), String.t()}]
  def leaves(rule), do: rule |> normalize() |> collect_leaves()

  defp collect_leaves(%{"all" => c}) when is_list(c), do: Enum.flat_map(c, &collect_leaves/1)
  defp collect_leaves(%{"any" => c}) when is_list(c), do: Enum.flat_map(c, &collect_leaves/1)

  defp collect_leaves(%{"field" => f, "op" => op}) when is_binary(f) and is_binary(op),
    do: [{f, op}]

  defp collect_leaves(_other), do: []

  @doc """
  Rewrite every reference to `from` in `rule` to `to`. A rule that does not
  mention `from` comes back as it was.
  """
  @spec rename(term(), String.t(), String.t()) :: rule() | nil
  def rename(rule, from, to), do: rule |> normalize() |> do_rename(from, to)

  defp do_rename(%{"all" => c} = r, from, to) when is_list(c),
    do: %{r | "all" => Enum.map(c, &do_rename(&1, from, to))}

  defp do_rename(%{"any" => c} = r, from, to) when is_list(c),
    do: %{r | "any" => Enum.map(c, &do_rename(&1, from, to))}

  defp do_rename(%{"field" => field} = leaf, from, to) when field == from,
    do: %{leaf | "field" => to}

  defp do_rename(other, _from, _to), do: other

  @doc """
  Whether `rule` holds for `values` (a map of field name to value, keys as
  strings). Never raises: a rule that is absent or has a broken shape is false.
  """
  @spec evaluate(term(), scope()) :: boolean()
  def evaluate(rule, values) do
    values = stringify_keys(values)

    case normalize(rule) do
      nil -> false
      rule -> if valid_shape?(rule), do: eval(rule, values), else: false
    end
  end

  defp eval(%{"all" => children}, values), do: Enum.all?(children, &eval(&1, values))
  defp eval(%{"any" => children}, values), do: Enum.any?(children, &eval(&1, values))

  defp eval(%{"field" => field, "op" => op} = leaf, values),
    do: test(op, Map.get(values, field), Map.get(leaf, "value"))

  defp test("empty", actual, _expected), do: empty?(actual)
  defp test("not_empty", actual, _expected), do: not empty?(actual)
  defp test("eq", actual, expected), do: matches?(actual, expected)
  defp test("neq", actual, expected), do: not matches?(actual, expected)
  defp test("in", actual, expected), do: Enum.any?(expected, &matches?(actual, &1))
  defp test("gt", actual, expected), do: compare(actual, expected) == :gt
  defp test("lt", actual, expected), do: compare(actual, expected) == :lt

  @doc "Whether `value` is empty by the module's definition."
  @spec empty?(term()) :: boolean()
  def empty?(nil), do: true
  def empty?(value) when is_binary(value), do: String.trim(value) == ""
  def empty?(value) when is_list(value), do: Enum.all?(value, &empty?/1)
  def empty?(_value), do: false

  # An empty actual value equals nothing; a list holds its members.
  defp matches?(actual, expected) when is_list(actual),
    do: Enum.any?(actual, &matches?(&1, expected))

  defp matches?(actual, expected) do
    a = number(actual)
    e = number(expected)

    cond do
      empty?(actual) -> false
      a != nil and e != nil -> a == e
      true -> text(actual) != nil and text(actual) == text(expected)
    end
  end

  # Only scalars have a text; a map (a media snapshot) equals nothing.
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text(_value), do: nil

  defp compare(actual, expected) do
    with false <- is_list(actual),
         {:ok, a, e} <- comparable(actual, expected) do
      cond do
        a > e -> :gt
        a < e -> :lt
        true -> :eq
      end
    else
      _uncomparable -> :error
    end
  end

  defp comparable(actual, expected) do
    with a when a != nil <- number(actual),
         e when e != nil <- number(expected) do
      {:ok, a, e}
    else
      _ -> dates(actual, expected)
    end
  end

  defp dates(actual, expected) do
    with {kind, a} <- moment(actual), {^kind, e} <- moment(expected) do
      {:ok, a, e}
    else
      _ -> :error
    end
  end

  # A date compares as days, a datetime as microseconds; the two never mix.
  defp moment(value) when is_binary(value) do
    value = String.trim(value)

    with :error <- date(value), do: datetime(value)
  end

  defp moment(_value), do: :error

  defp date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:date, Date.to_gregorian_days(date)}
      _ -> :error
    end
  end

  defp datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:datetime, DateTime.to_unix(dt, :microsecond)}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} ->
            {:datetime,
             naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)}

          _ ->
            :error
        end
    end
  end

  # Booleans are not numbers; a string is one only when all of it is.
  defp number(value) when is_boolean(value), do: nil
  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case value |> String.trim() |> Float.parse() do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_value), do: nil

  @doc """
  What each definition in `defs` comes to for `values`: `%{name => %{hidden?,
  required?}}`. `hidden?` is a `visible_when` that does not hold; `required?`
  is the static `required` or a `required_when` that holds, and never true for
  a hidden field. Pass `required_when: false` for a write that must not
  enforce `required_when` (a restore, a copy).
  """
  @spec effective([map()], scope(), keyword()) :: %{
          String.t() => %{hidden?: boolean(), required?: boolean()}
        }
  def effective(defs, values, opts \\ []) do
    values = stringify_keys(values)
    enforce? = Keyword.get(opts, :required_when, true)

    Map.new(defs, fn def ->
      hidden? = holds?(Map.get(def, :visible_when), values, true) == false

      required? =
        not hidden? and
          (def.required == true or
             (enforce? and holds?(Map.get(def, :required_when), values, false)))

      {def.name, %{hidden?: hidden?, required?: required?}}
    end)
  end

  @doc """
  `defs` with `required` set to what `effective/3` says, for the write path:
  the existing per-field coercion then needs to know nothing about rules.
  """
  @spec apply_to([map()], scope(), keyword()) :: [map()]
  def apply_to(defs, values, opts \\ []) do
    if Enum.any?(defs, &conditional?/1) do
      state = effective(defs, values, opts)
      Enum.map(defs, &%{&1 | required: state[&1.name].required?})
    else
      defs
    end
  end

  @doc "Whether a definition carries either rule."
  @spec conditional?(map()) :: boolean()
  def conditional?(def),
    do:
      normalize(Map.get(def, :visible_when)) != nil or
        normalize(Map.get(def, :required_when)) != nil

  # No rule, or one that cannot be read, answers `default` — a broken rule
  # never hides a field or blocks a save.
  defp holds?(rule, values, default) do
    rule = normalize(rule)

    if rule != nil and valid_shape?(rule), do: eval(rule, values), else: default
  end

  defp stringify_keys(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_other), do: %{}
end
