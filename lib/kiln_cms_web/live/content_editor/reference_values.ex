defmodule KilnCMSWeb.ContentEditor.ReferenceValues do
  @moduledoc """
  The content editor's wire form for a `:reference` custom field that allows
  several target types (R2, `FieldDefinition.target_types`).

  Such a field's write must name each item's type (`%{"id", "type"}`), but a
  `<select>` option or a hidden input posts one string. So the editor posts a
  `"type:id"` token, the way the fragment picker does (#479), and
  `normalize/2` turns every token back into the map before the params reach
  the form. A field that allows one type keeps posting bare ids, exactly as
  before R2.

  Deliberately small: the search-as-you-type picker with type badges is R9,
  which replaces the inputs this serves.
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
  Turn the tokens a polymorphic reference field posted into
  `%{"type", "id"}` maps, in `params["custom_fields"]`. Other fields, blanks
  and values already maps pass through untouched.
  """
  @spec normalize(map(), [map()]) :: map()
  def normalize(%{"custom_fields" => %{} = custom} = params, definitions) do
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

  def normalize(params, _definitions), do: params

  defp untokenize(values) when is_list(values), do: Enum.map(values, &untokenize/1)

  defp untokenize(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [type, id] when type != "" and id != "" -> %{"type" => type, "id" => id}
      _bare -> value
    end
  end

  defp untokenize(value), do: value
end
