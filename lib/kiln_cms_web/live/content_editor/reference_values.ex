defmodule KilnCMSWeb.ContentEditor.ReferenceValues do
  @moduledoc """
  The content editor's wire form for a `:reference` custom field that allows
  several target types (R2, `FieldDefinition.target_types`).

  Such a field's write must name each item's type (`%{"id", "type"}`), but a
  hidden input posts one string. So the reference picker
  (`KilnCMSWeb.ContentEditor.ReferencePicker`) keys each row by a
  `"type:id"` token, the way the fragment picker does (#479), and
  `normalize/2` turns every token back into the map before the params reach
  the form. A field that allows one type keeps posting bare ids, exactly as
  before R2.

  It also carries a connection's **link values** (R3). The picker names each
  row's link inputs `_kiln_ref_link[<field>][<row key>][<link field>]`, beside
  `custom_fields`, since a hidden id input cannot hold them; `normalize/2`
  folds each row's values into its item as `"link"` and drops the side param.
  """
  alias KilnCMS.CMS.FieldDefinition

  @doc "Whether a definition is a reference field allowing more than one type."
  @spec polymorphic?(map()) :: boolean()
  def polymorphic?(%{field_type: :reference} = definition),
    do: length(FieldDefinition.reference_targets(definition)) > 1

  def polymorphic?(_definition), do: false

  @doc "The token a polymorphic field's input posts for one record."
  @spec token(String.t(), String.t()) :: String.t()
  def token(type, id), do: type <> ":" <> id

  @doc """
  The keys of a stored or posted value, in order, the way the field's inputs
  post them: `"type:id"` tokens on a polymorphic field (an item that names no
  type posts its bare id, which the write then refuses by name), bare ids on
  every other.
  """
  @spec keys(term(), boolean()) :: [String.t()]
  def keys(value, polymorphic?) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id, "type" => type}
      when polymorphic? and is_binary(id) and id != "" and
             is_binary(type) and type != "" ->
        [token(type, id)]

      %{"id" => id} when is_binary(id) and id != "" ->
        [id]

      key when is_binary(key) and key != "" ->
        [key]

      _blank ->
        []
    end)
  end

  @doc """
  Each item of a stored or posted value, keyed as `keys/2` keys it: the item
  itself (a snapshot, a map, or the posted key), in order, blanks dropped.
  """
  @spec entries(term(), boolean()) :: [{String.t(), term()}]
  def entries(value, polymorphic?) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn item ->
      case keys(item, polymorphic?) do
        [key] -> [{key, item}]
        [] -> []
      end
    end)
  end

  @doc """
  The link values (R3) each connection of a value carries, by row key —
  what the picker fills its link inputs from.
  """
  @spec links(term(), map()) :: %{String.t() => map()}
  def links(value, definition) do
    value
    |> entries(polymorphic?(definition))
    |> Enum.flat_map(fn
      {key, %{"link" => %{} = link}} -> [{key, link}]
      _other -> []
    end)
    |> Map.new()
  end

  @doc """
  Turn the tokens a polymorphic reference field posted into
  `%{"type", "id"}` maps, in `params["custom_fields"]`, and fold each row's
  posted link values in as its `"link"` (R3). Other fields, blanks and values
  already maps pass through untouched.
  """
  @spec normalize(map(), [map()]) :: map()
  def normalize(%{"custom_fields" => %{} = custom} = params, definitions) do
    {posted_links, params} = Map.pop(params, "_kiln_ref_link", %{})
    custom = fold_links(custom, posted_links, definitions)

    names = for definition <- definitions, polymorphic?(definition), do: definition.name

    custom =
      Enum.reduce(names, custom, fn name, custom ->
        case custom do
          %{^name => value} -> Map.put(custom, name, untokenize(value))
          _absent -> custom
        end
      end)

    Map.put(params, "custom_fields", custom)
  end

  def normalize(params, _definitions) when is_map(params),
    do: Map.delete(params, "_kiln_ref_link")

  def normalize(params, _definitions), do: params

  defp fold_links(custom, %{} = posted, definitions) do
    Enum.reduce(definitions, custom, fn definition, custom ->
      with %{} = rows <- Map.get(posted, definition.name),
           {:ok, value} <- Map.fetch(custom, definition.name) do
        Map.put(custom, definition.name, put_links(value, rows, polymorphic?(definition)))
      else
        _ -> custom
      end
    end)
  end

  defp fold_links(custom, _posted, _definitions), do: custom

  defp put_links(values, rows, polymorphic?) when is_list(values),
    do: Enum.map(values, &put_links(&1, rows, polymorphic?))

  defp put_links(value, rows, polymorphic?) do
    case keys(value, polymorphic?) do
      [key] ->
        case Map.get(rows, key) do
          %{} = link -> value |> as_item() |> Map.put("link", link)
          _none -> value
        end

      [] ->
        value
    end
  end

  defp as_item(%{} = item), do: item

  defp as_item(key) when is_binary(key) do
    case untokenize(key) do
      %{} = item -> item
      id -> %{"id" => id}
    end
  end

  defp untokenize(values) when is_list(values), do: Enum.map(values, &untokenize/1)

  defp untokenize(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [type, id] when type != "" and id != "" -> %{"type" => type, "id" => id}
      _bare -> value
    end
  end

  defp untokenize(value), do: value
end
