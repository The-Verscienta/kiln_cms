defmodule KilnCMS.CMS.FieldConstraints do
  @moduledoc """
  The value constraints a `FieldDefinition` carries in its `validation` map
  (#2276), and the pure check of a coerced value against them.

  `Changes.ApplyCustomFields` calls `check/3` on a value *after* coercion
  (trimmed, JSON-native), so every write surface — editor, JSON:API, GraphQL,
  MCP, importers — shares one rule. `Validations.FieldConstraints` uses
  `keys/0`, `allowed_keys/2`, `compile/1` and `check_default/2` to keep a
  definition's own `validation` sound when it is saved.

  ## Constraints

    * `min` / `max` — inclusive bounds on an `:integer` or `:float`;
    * `min_length` / `max_length` — grapheme counts on a `:string`, `:url` or
      plain `:text` (a rich `:text` is HTML, so its length means nothing);
    * `pattern` — a regular expression the whole value must match
      (anchored, unicode), with `pattern_message` as the admin's own
      explanation when it does not;
    * `unique` — recorded here and shape-checked on save; enforced by the
      write path (`KilnCMS.CMS.UniqueValues`), not by `check/3`.

  Only non-blank values are checked: a blank optional field is simply empty,
  and `required` is the coercion's concern. A scalar list (`multiple`
  string, integer, url, …) is checked per item (`tags[1]`); a `:group` per row and sub-field
  (`dosages[2].unit`), with the sub-field's own `validation`.

  ## Safety

  A pattern runs through `:re.run/3` with match limits and only against
  values up to 2,000 characters; a value past that, or a pattern that hits a
  limit (catastrophic backtracking), does not match. Nothing in a constraint
  is evaluated as code.

  ## Errors

  `check/3` returns `{path, label, {:full, text}}` problems: `text` is a
  complete, translated sentence naming `Label (path)`, which
  `Changes.ApplyCustomFields` reports as is rather than prefixing again.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @keys ~w(min max min_length max_length pattern pattern_message unique)
  @max_subject 2_000
  @match_limit 100_000
  @recursion_limit 1_000

  @type problem :: {String.t(), String.t(), {:full, String.t()}}

  @doc "Every key a `validation` map may carry."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  The keys that mean something on a field of `type` (with `format` for
  `:text`).
  """
  @spec allowed_keys(atom(), atom() | nil) :: [String.t()]
  def allowed_keys(type, _format) when type in [:integer, :float], do: ~w(min max unique)

  def allowed_keys(type, _format) when type in [:string, :url],
    do: ~w(min_length max_length pattern pattern_message unique)

  def allowed_keys(:text, :plain), do: ~w(min_length max_length pattern pattern_message)
  def allowed_keys(type, _format) when type in [:date, :datetime, :slug], do: ["unique"]
  def allowed_keys(_type, _format), do: []

  @doc """
  A `validation` map with string keys and no `nil` values, however it
  arrived (atom keys from Elixir, string keys from JSON).
  """
  @spec normalize(term()) :: map()
  def normalize(%{} = validation) do
    for {key, value} <- validation, not is_nil(value), into: %{}, do: {to_string(key), value}
  end

  def normalize(_other), do: %{}

  @doc "Whether `validation` asks for the field's values to be unique."
  @spec unique?(term()) :: boolean()
  def unique?(validation), do: normalize(validation)["unique"] == true

  @doc """
  Compile a constraint pattern the way `check/3` runs it: anchored to the
  whole value, unicode-aware. `{:error, reason}` carries a readable message.
  """
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def compile(pattern) when is_binary(pattern) do
    # On its own first: wrapped only, `a)|(b` would compile to an alternation
    # that escapes the anchors.
    with {:ok, _alone} <- Regex.compile(pattern, "u"),
         {:ok, regex} <- Regex.compile("\\A(?:" <> pattern <> ")\\z", "u") do
      {:ok, regex}
    else
      {:error, {reason, _position}} -> {:error, to_string(reason)}
    end
  end

  @doc """
  The problems with `value` (already coerced) against `def`'s constraints.

  `def` needs `field_type`, `name`, `label`, `validation` and, for a
  scalar list, `multiple`; a `:group` also its loaded `group_fields`.
  `path` defaults to the field's name and prefixes every problem's path.
  """
  @spec check(map(), term(), String.t() | nil) :: [problem()]
  def check(def, value, path \\ nil)

  def check(%{field_type: :group} = def, value, path) do
    path = path || def.name

    case value do
      rows when is_list(rows) ->
        rows
        |> Enum.with_index()
        |> Enum.flat_map(fn {row, index} -> check_row(def, row, "#{path}[#{index}]") end)

      %{} = row ->
        check_row(def, row, path)

      _other ->
        []
    end
  end

  def check(def, value, path) do
    path = path || def.name
    validation = normalize(Map.get(def, :validation))

    cond do
      validation == %{} ->
        []

      blank?(value) ->
        []

      is_list(value) ->
        value |> Enum.with_index() |> Enum.flat_map(&item(def, validation, path, &1))

      true ->
        scalar(def, validation, path, value)
    end
  end

  @doc "Check one group row's sub-field values; `path` names the row."
  @spec check_row(map(), term(), String.t()) :: [problem()]
  def check_row(group, %{} = row, path) when not is_struct(row) do
    group
    |> KilnCMS.CMS.FieldDefinition.group_fields()
    |> Enum.flat_map(fn sub ->
      check(sub, Map.get(row, sub.name), "#{path}.#{sub.name}")
    end)
  end

  def check_row(_group, _row, _path), do: []

  @doc """
  Problems with a definition's `default`, a string coerced to the field's
  type the way a blank input falls back to it.
  """
  @spec check_default(map(), String.t()) :: [{String.t(), String.t(), String.t()}]
  def check_default(%{field_type: type} = def, default) when is_binary(default) do
    value = String.trim(default)

    value =
      case type do
        :integer -> parse(Integer.parse(value))
        :float -> parse(Float.parse(value))
        _ -> value
      end

    # The save-time message is a tail ("must be at least 3"), not a sentence
    # naming the field, so the admin reads it under `validation`.
    def
    |> Map.merge(%{name: "default", label: "default"})
    |> check(value, "default")
    |> Enum.map(fn {path, label, {:full, text}} -> {path, label, tail(text, label, path)} end)
  end

  defp tail(text, label, path) do
    prefix = "#{label} (#{path}) "
    if String.starts_with?(text, prefix), do: String.replace_prefix(text, prefix, ""), else: text
  end

  defp parse({number, ""}), do: number
  defp parse(_other), do: nil

  # --- checks ------------------------------------------------------------

  # One item of a scalar list (`multiple` string, integer, url, …).
  defp item(def, validation, path, {value, index}) do
    if blank?(value), do: [], else: scalar(def, validation, "#{path}[#{index}]", value)
  end

  defp scalar(%{field_type: type} = def, validation, path, value)
       when type in [:integer, :float] and is_number(value) do
    field = field(def, path)

    problem(def, path, bound(validation["min"], value, :min, field)) ++
      problem(def, path, bound(validation["max"], value, :max, field))
  end

  defp scalar(%{field_type: type} = def, validation, path, value)
       when is_binary(value) and type in [:string, :url, :text] do
    if type == :text and Map.get(def, :format, :rich) != :plain do
      []
    else
      field = field(def, path)
      length = String.length(value)

      problem(def, path, min_length(validation["min_length"], length, field)) ++
        problem(def, path, max_length(validation["max_length"], length, field)) ++
        problem(def, path, pattern(validation, value, field))
    end
  end

  defp scalar(_def, _validation, _path, _value), do: []

  defp problem(_def, _path, nil), do: []
  defp problem(def, path, text), do: [{path, def.label, {:full, text}}]

  defp field(def, path), do: "#{def.label} (#{path})"

  defp bound(nil, _value, _kind, _field), do: nil

  defp bound(min, value, :min, field) when is_number(min) and value < min,
    do: dgettext("errors", "%{field} must be at least %{min}", field: field, min: number(min))

  defp bound(max, value, :max, field) when is_number(max) and value > max,
    do: dgettext("errors", "%{field} must be at most %{max}", field: field, max: number(max))

  defp bound(_limit, _value, _kind, _field), do: nil

  defp min_length(min, length, field) when is_integer(min) and length < min do
    dngettext(
      "errors",
      "%{field} must be at least %{count} character long",
      "%{field} must be at least %{count} characters long",
      min,
      field: field
    )
  end

  defp min_length(_min, _length, _field), do: nil

  defp max_length(max, length, field) when is_integer(max) and length > max do
    dngettext(
      "errors",
      "%{field} must be at most %{count} character long",
      "%{field} must be at most %{count} characters long",
      max,
      field: field
    )
  end

  defp max_length(_max, _length, _field), do: nil

  defp pattern(%{"pattern" => pattern} = validation, value, field) when is_binary(pattern) do
    if matches?(pattern, value) do
      nil
    else
      case validation["pattern_message"] do
        message when is_binary(message) and message != "" ->
          dgettext("errors", "%{field}: %{message}", field: field, message: message)

        _none ->
          dgettext("errors", "%{field} doesn't match the required format", field: field)
      end
    end
  end

  defp pattern(_validation, _value, _field), do: nil

  # A value too long to match safely, a pattern that no longer compiles and a
  # pattern that runs into a limit all fail to match rather than raise or hang.
  defp matches?(pattern, value) do
    with true <- String.length(value) <= @max_subject,
         {:ok, regex} <- compile(pattern),
         :match <-
           :re.run(value, regex.re_pattern, [
             {:capture, :none},
             {:match_limit, @match_limit},
             {:match_limit_recursion, @recursion_limit}
           ]) do
      true
    else
      _no_match -> false
    end
  end

  defp number(n) when is_float(n) and n == trunc(n), do: Integer.to_string(trunc(n))
  defp number(n), do: to_string(n)

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")
end
