defmodule KilnCMSWeb.FieldSelection do
  @moduledoc """
  The fields admin's side of a reference field's `selection` (#2285, part 3):
  the posted `field_definition[sel]` inputs turned into the `selection` map the
  resource validates, and a stored map read back as the same inputs and as a
  plain sentence. The vocabulary and every rule about it live in
  `KilnCMS.CMS.ReferenceSelection` and `KilnCMS.CMS.Validations.ReferenceSelection`;
  this module only translates and never judges, so the form shows the resource's
  own refusals.

  A field condition is an operator (equals, is one of, is not) and one text
  input; "is one of" takes values separated by commas. Values are cast to the field's type (numbers
  and booleans) so a stored `5` reads back as `5` and is saved as `5`.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.CMS.ReferenceSelection

  @doc """
  Replaces the posted `"sel"` map in `params` with `"selection"`: the map the
  admin built, or `nil` when nothing is set. Params without `"sel"` (a form
  that is not showing the step) are returned untouched. Types the admin has not
  ticked as targets are dropped, and so are blank rows.

  `catalog` maps a target type name to the equality fields it offers
  (`[%{name: .., field_type: ..}]`), used only to cast values.
  """
  @spec unpack(map(), [String.t()], map()) :: map()
  def unpack(%{"sel" => sel, "field_type" => "reference"} = params, targets, catalog)
      when is_map(sel) do
    selection =
      %{}
      |> put("states", states(sel["states"]))
      |> put("owner", if(sel["owner"] == "self", do: "self"))
      |> put("sort", if(sel["sort"] == "title", do: "title"))
      |> put("by_type", by_type(sel["by_type"], targets, catalog))
      |> put("create", create(sel["create"], targets))

    params
    |> Map.delete("sel")
    |> Map.put("selection", if(selection == %{}, do: nil, else: selection))
  end

  # Not a relationship (the step is hidden, or the kind was flipped to a
  # value): the posted rows mean nothing and a stored selection goes with the
  # relationship, so the form never saves a refusal the admin cannot see.
  def unpack(%{"field_type" => type} = params, _targets, _catalog) when type != "reference",
    do: params |> Map.delete("sel") |> Map.put("selection", nil)

  def unpack(%{"sel" => _sel} = params, _targets, _catalog), do: Map.delete(params, "sel")
  def unpack(params, _targets, _catalog), do: params

  # `create-on-type`: one target type, only one the field links to.
  defp create(type, targets) when is_binary(type),
    do: if(type in targets, do: %{"type" => type})

  defp create(_none, _targets), do: nil

  defp put(map, _key, value) when value in [nil, [], %{}, ""], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp states(states) when is_list(states),
    do: states |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

  defp states(_none), do: []

  defp by_type(%{} = by_type, targets, catalog) do
    for {type, entry} <- by_type, type in targets, is_map(entry), into: %{} do
      {type, type_entry(entry, Map.get(catalog, type, []))}
    end
    |> Map.reject(fn {_type, entry} -> entry == %{} end)
  end

  defp by_type(_none, _targets, _catalog), do: %{}

  defp type_entry(entry, fields) do
    %{}
    |> put("tags_any", ids(entry["tags_any"]))
    |> put("category", blank_to_nil(entry["category"]))
    |> put("fields", field_conditions(entry["fields"], fields))
  end

  defp ids(ids) when is_list(ids), do: ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
  defp ids(_none), do: []

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_other), do: nil

  defp field_conditions(%{} = fields, defs) do
    types = Map.new(defs, &{&1.name, &1.field_type})

    for {name, %{"value" => value} = row} <- fields,
        is_binary(value),
        text = String.trim(value),
        text != "",
        into: %{} do
      {name, condition(row["op"], text, Map.get(types, name))}
    end
  end

  defp field_conditions(_none, _defs), do: %{}

  defp condition("not_eq", text, type), do: %{"not_eq" => cast(text, type)}

  defp condition("in", text, type) do
    case text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [one] -> %{"in" => [cast(one, type)]}
      many -> %{"in" => Enum.map(many, &cast(&1, type))}
    end
  end

  defp condition(_eq, text, type), do: cast(text, type)

  defp cast(text, :integer) do
    case Integer.parse(text) do
      {n, ""} -> n
      _other -> text
    end
  end

  defp cast(text, :float) do
    case Float.parse(text) do
      {n, ""} -> n
      _other -> text
    end
  end

  defp cast("true", :boolean), do: true
  defp cast("false", :boolean), do: false
  defp cast(text, _type), do: text

  @doc """
  What the inputs show for a stored or posted selection: `states`, `owner?`,
  `sort`, and per type `tags`, `category` and `fields` (name to
  `{operator, text}`).
  """
  @spec view(term()) :: map()
  def view(selection) do
    map = ReferenceSelection.normalize(selection) || %{}

    %{
      states: Map.get(map, "states", []),
      owner?: Map.get(map, "owner") == "self",
      create: get_in(map, ["create", "type"]),
      sort: Map.get(map, "sort", "recent"),
      by_type:
        Map.new(Map.get(map, "by_type", %{}), fn {type, entry} ->
          {type,
           %{
             tags: Map.get(entry, "tags_any", []),
             category: Map.get(entry, "category"),
             fields: Map.new(Map.get(entry, "fields", %{}), fn {n, c} -> {n, row(c)} end)
           }}
        end)
    }
  end

  defp row(%{"in" => values}), do: {"in", Enum.map_join(values, ", ", &to_string/1)}
  defp row(%{"not_eq" => value}), do: {"not_eq", to_string(value)}
  defp row(value), do: {"eq", to_string(value)}

  @doc """
  The selection as a sentence for the admin: "Published Ingredients tagged
  vegan or raw, created by the editor, newest first." `lookup` names what the
  ids and field names stand for:
  `%{tags: %{id => name}, categories: %{id => name}, fields: %{type => %{name => label}},
  types: %{type => label}}`. An id the lookup does not know is shown as
  "(not found)". `nil` when no condition is set.
  """
  @spec sentence(term(), [String.t()], map()) :: String.t() | nil
  def sentence(selection, targets, lookup) do
    case ReferenceSelection.normalize(selection) do
      nil -> nil
      map -> build(map, targets, lookup)
    end
  end

  defp build(map, targets, lookup) do
    states = Map.get(map, "states", [])
    by_type = Map.get(map, "by_type", %{})
    single? = length(targets) == 1

    noun =
      case targets do
        [only] ->
          gettext("%{states} %{type} records",
            states: state_words(states),
            type: label(lookup, only)
          )

        _several ->
          gettext("%{states} records", states: state_words(states))
      end
      |> String.trim()
      |> upcase_first()

    parts =
      for {type, entry} <- Enum.sort(by_type),
          type in targets,
          c <- type_phrases(entry, lookup, type) do
        if single?, do: c, else: "#{label(lookup, type)}: #{c}"
      end

    owner = if map["owner"] == "self", do: [gettext("created by the editor")], else: []
    sort = if map["sort"] == "title", do: gettext("by title"), else: gettext("newest first")

    base = Enum.join([noun | parts ++ owner] ++ [sort], ", ") <> "."

    case get_in(map, ["create", "type"]) do
      type when is_binary(type) ->
        gettext("%{sentence} Typing a new name offers to create a draft %{type}.",
          sentence: base,
          type: label(lookup, type)
        )

      _none ->
        base
    end
  end

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(other), do: other

  defp state_words([]), do: ""

  defp state_words(states),
    do: Enum.map_join(states, " " <> gettext("or") <> " ", &state_name/1)

  defp state_name("draft"), do: gettext("Draft")
  defp state_name("in_review"), do: gettext("In review")
  defp state_name("published"), do: gettext("Published")
  defp state_name("archived"), do: gettext("Archived")
  defp state_name(other), do: to_string(other)

  defp label(lookup, type), do: get_in(lookup, [:types, type]) || type

  defp type_phrases(entry, lookup, type) do
    tags =
      case Map.get(entry, "tags_any", []) do
        [] ->
          []

        ids ->
          names = Enum.map(ids, &Map.get(lookup.tags, &1, gettext("(not found)")))
          [gettext("tagged %{tags}", tags: Enum.join(names, " " <> gettext("or") <> " "))]
      end

    category =
      case Map.get(entry, "category") do
        nil ->
          []

        id ->
          [
            gettext("in %{category}",
              category: Map.get(lookup.categories, id, gettext("(not found)"))
            )
          ]
      end

    fields =
      for {name, condition} <- Enum.sort(Map.get(entry, "fields", %{})) do
        label = get_in(lookup, [:fields, type, name]) || "#{name} " <> gettext("(not found)")
        gettext("%{field} %{condition}", field: label, condition: condition_words(condition))
      end

    tags ++ category ++ fields
  end

  defp condition_words(%{"in" => values}),
    do: gettext("is %{values}", values: Enum.join(values, " " <> gettext("or") <> " "))

  defp condition_words(%{"not_eq" => value}),
    do: gettext("is not %{value}", value: to_string(value))

  defp condition_words(value), do: gettext("is %{value}", value: to_string(value))
end
