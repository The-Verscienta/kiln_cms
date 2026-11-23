defmodule KilnCMSWeb.ContentEditor.FlexibleItems do
  @moduledoc """
  The content editor's wire form for a `:flexible` custom field (#2282): a
  list of typed items, each one a card of its item type's sub-fields. The
  sibling of `KilnCMSWeb.ContentEditor.GroupRows`, with the one difference that
  matters: an item has an identity.

  An item's inputs are named into the field's own key of `custom_fields`, one
  map per item keyed by its position (`…[<field>][<index>][<sub-field>]`),
  which `normalize/2` folds into the ordered list `ApplyCustomFields`
  coerces, recursing into the lists of nested flexible sub-fields. Three keys
  carry the item itself and are **kept** (`GroupRows` strips every key that
  starts with `_`): `_id`, `_type` and `_settings` (the sub-fields marked
  `item_setting`). Every other `_` key is a blank marker or one of LiveView's
  `_unused_…` companions, and is dropped, as it is there.

  Positions are a transport detail. Everything the editor does to an item —
  add, remove, move, duplicate, a dragged order — addresses it by its `_id`,
  so an event cannot land on the wrong card after the list has moved under it.
  An address is a string of `/`-separated segments, the field's name first,
  then alternating an item's `_id` and the name of one of its flexible
  sub-fields:

    * `"sections"` — the field's own list;
    * `"sections/6f1c…"` — one of its items;
    * `"sections/6f1c…/blocks"` — the list a nested flexible sub-field holds;
    * `"sections/6f1c…/blocks/a02d…"` — one of those items.

  Errors name an item by its posted position (`sections[2].headline`), which
  `errors/3` turns into the same addresses.
  """

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMSWeb.ContentEditor.GroupRows
  alias KilnCMSWeb.ContentEditor.ReferenceValues

  @meta ["_id", "_type", "_settings"]

  # The default cap on a field with no `max_items`, the key `ApplyCustomFields`
  # reads.
  @default_max_items Application.compile_env(:kiln_cms, [:flexible, :max_items], 100)

  # --- the wire form ------------------------------------------------------------

  @doc """
  Fold each flexible field's posted items (a map keyed by position) into an
  ordered list, keeping `_id`, `_type` and `_settings` and dropping the blank
  markers, recursing into nested flexible sub-fields. Lists, other fields and
  absent fields pass through.

  An item whose `_type` is not one of the field's item types (an orphan) is
  reduced to its `_id` and `_type`: the editor never posts its content back,
  and an item with nothing else is the blank card a save drops.
  """
  @spec normalize(map(), [map()]) :: map()
  def normalize(%{"custom_fields" => %{} = custom} = params, definitions) do
    custom =
      Enum.reduce(definitions, custom, fn
        %{field_type: :flexible, name: name} = definition, custom ->
          case custom do
            %{^name => value} -> Map.put(custom, name, normalize_list(value, definition))
            _absent -> custom
          end

        _other, custom ->
          custom
      end)

    Map.put(params, "custom_fields", custom)
  end

  def normalize(params, _definitions), do: params

  defp normalize_list(%{} = posted, definition) when not is_struct(posted) do
    posted
    |> Enum.flat_map(fn {key, item} ->
      case Integer.parse(to_string(key)) do
        {index, ""} -> [{index, item}]
        _marker -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&normalize_item(elem(&1, 1), definition))
  end

  defp normalize_list(items, definition) when is_list(items),
    do: Enum.map(items, &normalize_item(&1, definition))

  defp normalize_list(other, _definition), do: other

  defp normalize_item(%{} = item, definition) when not is_struct(item) do
    item = Map.reject(item, fn {key, _value} -> marker?(key) end)

    case Enum.find(FieldDefinition.item_types(definition), &(&1.name == item["_type"])) do
      nil -> orphan(item)
      type -> normalize_sub_fields(item, type)
    end
  end

  defp normalize_item(other, _definition), do: other

  # Only a named type that this field does not have is an orphan; an item with
  # no `_type` at all is left for the save to refuse.
  defp orphan(%{"_type" => type} = item) when is_binary(type) and type != "",
    do: Map.take(item, ["_id", "_type"])

  defp orphan(item), do: item

  defp normalize_sub_fields(item, type) do
    item =
      case item do
        %{"_settings" => %{} = settings} when not is_struct(settings) ->
          Map.put(item, "_settings", Map.reject(settings, fn {key, _} -> marker?(key) end))

        _other ->
          item
      end

    subs = FieldDefinition.group_fields(type)

    item =
      subs
      |> Enum.filter(&(&1.field_type == :flexible))
      |> Enum.reduce(item, fn sub, item ->
        case fetch_sub(item, sub) do
          {:ok, value} -> put_sub(item, sub, normalize_list(value, sub))
          :error -> item
        end
      end)

    # A reference sub-field that allows several types posts a `"type:id"` token
    # in its one hidden input; the write needs the `%{"id", "type"}` map.
    subs
    |> Enum.filter(&(&1.field_type == :reference and ReferenceValues.polymorphic?(&1)))
    |> Enum.reduce(item, fn sub, item ->
      case fetch_sub(item, sub) do
        {:ok, value} -> put_sub(item, sub, ReferenceValues.untokenize(value))
        :error -> item
      end
    end)
  end

  defp marker?(key), do: String.starts_with?(to_string(key), "_") and to_string(key) not in @meta

  # An item's value for a sub-field: content sits on the item, a setting
  # (`item_setting`) under `_settings`.
  defp fetch_sub(item, %{name: name} = sub) do
    if setting?(sub) do
      case item do
        %{"_settings" => %{} = settings} -> Map.fetch(settings, name)
        _none -> :error
      end
    else
      Map.fetch(item, name)
    end
  end

  defp put_sub(item, %{name: name} = sub, value) do
    if setting?(sub) do
      settings = if is_map(item["_settings"]), do: item["_settings"], else: %{}
      Map.put(item, "_settings", Map.put(settings, name, value))
    else
      Map.put(item, name, value)
    end
  end

  @doc "Whether `sub` is one of its item type's settings (`item_setting`)."
  @spec setting?(map()) :: boolean()
  def setting?(sub), do: Map.get(sub, :item_setting) == true

  # --- reading ------------------------------------------------------------------

  @doc """
  A flexible field's items as the editor shows them: what was posted while the
  form holds it — blank cards a save would drop included — else the stored
  value.
  """
  @spec posted(Phoenix.HTML.Form.t() | AshPhoenix.Form.t(), String.t()) :: [map()]
  def posted(form, name), do: form |> GroupRows.posted(name) |> items()

  @doc "The item maps of a value; anything else is no items."
  @spec items(term()) :: [map()]
  def items(items) when is_list(items),
    do: Enum.filter(items, &(is_map(&1) and not is_struct(&1)))

  def items(_other), do: []

  @doc """
  An item's key in a list: its `_id`, or — for an item that somehow has none —
  a positional stand-in, so a card can still be drawn (it cannot be addressed).
  """
  @spec key(map(), non_neg_integer()) :: String.t()
  def key(%{"_id" => id}, _index) when is_binary(id) and id != "", do: id
  def key(_item, index), do: "p#{index}"

  @doc "The item type of `item` among `definition`'s, or nil for an orphan."
  @spec type(map(), map()) :: map() | nil
  def type(definition, item),
    do: Enum.find(FieldDefinition.item_types(definition), &(&1.name == item["_type"]))

  @doc "A flexible sub-field's items on `item`."
  @spec sub_items(map(), map()) :: [map()]
  def sub_items(item, sub) do
    case fetch_sub(item, sub) do
      {:ok, value} -> items(value)
      :error -> []
    end
  end

  @doc """
  A short line saying what an item holds: its first non-blank text-like
  content value, markup stripped, cut at 80 characters. nil when it has none.
  """
  @spec summary(map(), map() | nil) :: String.t() | nil
  def summary(_item, nil), do: nil

  def summary(item, type) do
    type
    |> FieldDefinition.group_fields()
    |> Enum.reject(&(setting?(&1) or &1.field_type in [:flexible, :media, :reference]))
    |> Enum.find_value(fn sub -> sub_summary(Map.get(item, sub.name)) end)
  end

  defp sub_summary(value) when is_binary(value) do
    text =
      value
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      text == "" -> nil
      String.length(text) > 80 -> String.slice(text, 0, 79) <> "…"
      true -> text
    end
  end

  defp sub_summary(value) when is_number(value), do: to_string(value)
  defp sub_summary(_value), do: nil

  # --- bounds -------------------------------------------------------------------

  @doc "Whether a list already holds the field's `max_items` (the default cap, when it sets none)."
  @spec full?([map()], map()) :: boolean()
  def full?(items, definition),
    do: length(items) >= (Map.get(definition, :max_items) || @default_max_items)

  @doc "Whether a list already holds its item type's `max_items`."
  @spec type_full?([map()], map()) :: boolean()
  def type_full?(items, %{max_items: max} = type) when is_integer(max),
    do: Enum.count(items, &(&1["_type"] == type.name)) >= max

  def type_full?(_items, _type), do: false

  @doc "Whether removing an item would take the list below the field's `min_items`."
  @spec at_minimum?([map()], map()) :: boolean()
  def at_minimum?(items, %{min_items: min}) when is_integer(min), do: length(items) <= min
  def at_minimum?(_items, _definition), do: false

  # --- addresses ----------------------------------------------------------------

  @doc """
  An address split into the field's name and the segments after it:
  `sections/6f1c/blocks` is `{"sections", ["6f1c", "blocks"]}`.
  """
  @spec parse(String.t()) :: {String.t(), [String.t()]}
  def parse(address) do
    [name | segments] = String.split(address, "/")
    {name, segments}
  end

  @doc "An address as a DOM id fragment."
  @spec dom_key(String.t()) :: String.t()
  def dom_key(address), do: String.replace(address, "/", "-")

  @doc """
  Rewrite the list at `segments` (the address after the field's name) through
  `fun`, which gets the list and the definition that governs it (the field
  itself, or a nested flexible sub-field) and returns `{:ok, items}` or
  `:error`. `:error` too when the address names no list.
  """
  @spec update_list([map()], map(), [String.t()], ([map()], map() -> {:ok, [map()]} | :error)) ::
          {:ok, [map()]} | :error
  def update_list(items, definition, [], fun), do: fun.(items, definition)

  def update_list(items, definition, [id, sub_name | rest], fun) do
    with {item, index} <- find(items, id),
         %{} = type <- type(definition, item),
         %{field_type: :flexible} = sub <-
           Enum.find(FieldDefinition.group_fields(type), &(&1.name == sub_name)),
         {:ok, updated} <- update_list(sub_items(item, sub), sub, rest, fun) do
      {:ok, List.replace_at(items, index, put_sub(item, sub, updated))}
    else
      _no_such_list -> :error
    end
  end

  def update_list(_items, _definition, _segments, _fun), do: :error

  @doc """
  `value` set on the single-valued sub-field `sub_name` of the item `id`, when
  that sub-field is a `field_type` (`:media` or `:reference`) of the item's
  type and holds one value (`multiple` off). `:error` for an item that is gone,
  a sub-field the item's type does not have, or one that is another type, so an
  event naming an address and a sub-field can write nothing the editor's own
  input could not. A reference that allows several types takes the picker's
  `"type:id"` token and stores the `%{"id", "type"}` map; `""` clears.
  """
  @spec put_value([map()], map(), String.t(), String.t(), :media | :reference, term()) ::
          {:ok, [map()]} | :error
  def put_value(items, definition, id, sub_name, field_type, value)
      when field_type in [:media, :reference] do
    with {item, index} <- find(items, id),
         %{} = item_type <- type(definition, item),
         %{field_type: ^field_type} = sub <-
           Enum.find(FieldDefinition.group_fields(item_type), &(&1.name == sub_name)),
         true <- Map.get(sub, :multiple) != true do
      value =
        if field_type == :reference and ReferenceValues.polymorphic?(sub),
          do: ReferenceValues.untokenize(value),
          else: value

      {:ok, List.replace_at(items, index, put_sub(item, sub, value))}
    else
      _no_such_sub_field -> :error
    end
  end

  defp find(items, id) do
    items
    |> Enum.with_index()
    |> Enum.find(fn {item, index} -> key(item, index) == id end)
  end

  # --- editing ------------------------------------------------------------------

  @doc """
  One more, blank item of `type_name` at the end — unless the list is full, or
  the type is, or the field has no such type.
  """
  @spec add([map()], map(), String.t()) :: {:ok, [map()]} | :error
  def add(items, definition, type_name) do
    with %{} = type <- Enum.find(FieldDefinition.item_types(definition), &(&1.name == type_name)),
         false <- full?(items, definition),
         false <- type_full?(items, type) do
      {:ok, items ++ [%{"_id" => Ash.UUID.generate(), "_type" => type.name}]}
    else
      _refused -> :error
    end
  end

  @doc "The items without the one `id`."
  @spec remove([map()], String.t()) :: {:ok, [map()]} | :error
  def remove(items, id) do
    case find(items, id) do
      {_item, index} -> {:ok, List.delete_at(items, index)}
      nil -> :error
    end
  end

  @doc "The item `id` swapped with its neighbour above (`\"up\"`) or below."
  @spec move([map()], String.t(), String.t()) :: {:ok, [map()]} | :error
  def move(items, id, dir) do
    with {item, index} <- find(items, id),
         other = if(dir == "up", do: index - 1, else: index + 1),
         true <- other >= 0 and other < length(items) do
      {:ok,
       items |> List.replace_at(index, Enum.at(items, other)) |> List.replace_at(other, item)}
    else
      _no_move -> :error
    end
  end

  @doc """
  The items in a dragged order, by `_id`. Anything that is not exactly a
  permutation of the ids the list holds now — a stale page, a hand-made
  event — changes nothing, so a drag can reorder items but never drop or copy
  one.
  """
  @spec reorder([map()], term()) :: {:ok, [map()]} | :error
  def reorder(items, order) when is_list(order) do
    keyed =
      items |> Enum.with_index() |> Map.new(fn {item, index} -> {key(item, index), item} end)

    if Enum.all?(order, &is_binary/1) and Enum.sort(order) == Enum.sort(Map.keys(keyed)) and
         length(order) == length(items),
       do: {:ok, Enum.map(order, &Map.fetch!(keyed, &1))},
       else: :error
  end

  def reorder(_items, _order), do: :error

  @doc """
  A copy of the item `id` right after it, every `_id` in it (its own and its
  nested items') new — unless the list is full or the item's type is.
  """
  @spec duplicate([map()], map(), String.t()) :: {:ok, [map()]} | :error
  def duplicate(items, definition, id) do
    with {item, index} <- find(items, id),
         false <- full?(items, definition),
         false <- duplicate_type_full?(items, definition, item) do
      {:ok, List.insert_at(items, index + 1, remint(item))}
    else
      _refused -> :error
    end
  end

  defp duplicate_type_full?(items, definition, item) do
    case type(definition, item) do
      nil -> false
      type -> type_full?(items, type)
    end
  end

  defp remint(%{"_id" => _, "_type" => _} = item),
    do:
      item
      |> Map.new(fn {key, value} -> {key, remint(value)} end)
      |> Map.put("_id", Ash.UUID.generate())

  defp remint(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, remint(value)} end)

  defp remint(list) when is_list(list), do: Enum.map(list, &remint/1)
  defp remint(other), do: other

  # --- autosave -----------------------------------------------------------------

  @doc """
  The flexible fields whose posted items include a blank card — one a save
  drops (`ApplyCustomFields`), at any depth — as `%{name => items}`: what an
  autosave would otherwise take off the screen. The editor validates these
  back onto the rebuilt form, as it does a repeating group's blank rows.
  """
  @spec pending(map(), [map()]) :: map()
  def pending(%{"custom_fields" => %{} = custom}, definitions) do
    for %{field_type: :flexible, name: name} <- definitions,
        items = Map.get(custom, name),
        is_list(items) and any_blank?(items),
        into: %{},
        do: {name, items}
  end

  def pending(_params, _definitions), do: %{}

  defp any_blank?(items) do
    Enum.any?(items, fn
      %{} = item -> blank_card?(item) or Enum.any?(Map.values(item), &nested_blank?/1)
      _other -> false
    end)
  end

  defp nested_blank?(items) when is_list(items), do: any_blank?(items)

  defp nested_blank?(%{} = settings) when not is_struct(settings),
    do: Enum.any?(Map.values(settings), &nested_blank?/1)

  defp nested_blank?(_value), do: false

  # `ApplyCustomFields`' own test, so "will the save drop this card" agrees.
  defp blank_card?(%{} = item) when not is_struct(item),
    do: item |> Map.drop(@meta) |> Map.values() |> Enum.all?(&blank_value?/1)

  defp blank_value?(items) when is_list(items), do: Enum.all?(items, &blank_value?/1)
  defp blank_value?(%{} = item) when not is_struct(item), do: blank_card?(item)
  defp blank_value?(value), do: String.trim(to_string(value || "")) == ""

  # --- errors -------------------------------------------------------------------

  @doc """
  A field's validation messages sorted by where they belong, from the path
  each names (`Headline (sections[2].headline) is required`), resolved
  through the posted `items` to the `_id` addresses cards carry:

    * `:items` — `%{item_address => %{item: [message], cells: %{sub => [message]}}}`,
      a sub-field's message with its label, a whole item's without;
    * `:lists` — `%{list_address => [message]}` for a nested flexible
      sub-field's own bounds;
    * `:field` — everything else (the field's own "is required", a count
      outside `min_items`/`max_items`), as given.
  """
  @spec errors([String.t()], map(), [map()]) :: %{items: map(), lists: map(), field: [String.t()]}
  def errors(messages, definition, items) do
    name = definition.name

    pattern =
      ~r/\A(?<label>.*?) \((?<path>#{Regex.escape(name)}(?:\[\d+\]|\.[a-z_][a-z0-9_]*)*)\) (?<message>.*)\z/s

    Enum.reduce(messages, %{items: %{}, lists: %{}, field: []}, fn message, acc ->
      with %{"label" => label, "path" => path, "message" => text} <-
             Regex.named_captures(pattern, message),
           tokens when tokens != [] <- tokens(String.replace_prefix(path, name, "")),
           {:ok, target} <- locate(tokens, name, items, definition) do
        file(acc, target, label, text)
      else
        _unplaced -> %{acc | field: acc.field ++ [message]}
      end
    end)
  end

  defp tokens(path) do
    ~r/\[(\d+)\]|\.([a-z_][a-z0-9_]*)/
    |> Regex.scan(path)
    |> Enum.map(fn
      [_, index] -> {:index, String.to_integer(index)}
      [_, "", name] -> {:name, name}
    end)
  end

  defp locate([{:index, index} | rest], list_address, items, definition) do
    case Enum.at(items, index) do
      nil ->
        :error

      item ->
        address = list_address <> "/" <> key(item, index)
        locate_in_item(rest, address, item, type(definition, item))
    end
  end

  defp locate(_tokens, _list_address, _items, _definition), do: :error

  defp locate_in_item([], address, _item, _type), do: {:ok, {:item, address}}
  defp locate_in_item([{:name, "_type"}], address, _item, _type), do: {:ok, {:item, address}}

  defp locate_in_item([{:name, "_settings"} | rest], address, item, type),
    do: locate_in_item(rest, address, item, type)

  defp locate_in_item([{:name, sub_name} | rest], address, item, type) do
    sub = type && Enum.find(FieldDefinition.group_fields(type), &(&1.name == sub_name))

    case {sub, rest} do
      {%{field_type: :flexible}, [{:index, _} | _]} ->
        locate(rest, address <> "/" <> sub_name, sub_items(item, sub), sub)

      {%{field_type: :flexible}, []} ->
        {:ok, {:list, address <> "/" <> sub_name}}

      {nil, _rest} ->
        {:ok, {:item, address}}

      {_cell, _rest} ->
        {:ok, {:cell, address, sub_name}}
    end
  end

  defp locate_in_item(_tokens, address, _item, _type), do: {:ok, {:item, address}}

  defp file(acc, {:item, address}, _label, text),
    do: update_in(acc.items, &add_item_error(&1, address, :item, text))

  defp file(acc, {:cell, address, sub}, label, text),
    do: update_in(acc.items, &add_item_error(&1, address, {:cell, sub}, "#{label} #{text}"))

  defp file(acc, {:list, address}, _label, text),
    do:
      update_in(
        acc.lists,
        &Map.update(&1, address, [text], fn messages -> messages ++ [text] end)
      )

  defp add_item_error(items, address, where, message) do
    entry = Map.get(items, address, %{item: [], cells: %{}})

    entry =
      case where do
        :item ->
          %{entry | item: entry.item ++ [message]}

        {:cell, sub} ->
          %{entry | cells: Map.update(entry.cells, sub, [message], &(&1 ++ [message]))}
      end

    Map.put(items, address, entry)
  end

  @doc "Whether any error sits on the item at `address` or anywhere below it."
  @spec errors?(map(), String.t()) :: boolean()
  def errors?(problems, address) do
    below? = &(&1 == address or String.starts_with?(&1, address <> "/"))
    Enum.any?(Map.keys(problems.items), below?) or Enum.any?(Map.keys(problems.lists), below?)
  end
end
