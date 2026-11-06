defmodule KilnCMSWeb.Graphql.CustomFieldValues do
  @moduledoc """
  The `CustomFieldValue` interface and the value objects behind it (#2290):
  what `fields(names:)` on every content type returns.

  The schema is compiled and the same for every site, so a field an admin
  defines later cannot become a GraphQL field of its own. Each value is instead
  wrapped in an object that names its kind (`FloatValue`, `MediaValue`, …), and
  a client narrows with `... on FloatValue { value }`. The scalar accessors
  (`customString(name:)` and friends, `KilnCMSWeb.Graphql.ContentRecord.Notation`)
  are the shortcut for a single field.

  `KilnCMSWeb.Graphql.CustomFields` builds the values; `resolve_type/2` maps
  each one back to its object.

  A `multiple` field is a `ListValue` whatever its item type, so a
  `:reference` field with `multiple: true` is a `ListValue` of `ReferenceValue`s,
  one id each. Use `references(field:)` for the records behind an id.
  """
  use Absinthe.Schema.Notation

  alias KilnCMSWeb.GraphqlLimits

  @doc "Absinthe `resolve_type` for `CustomFieldValue`."
  @spec resolve_type(map(), Absinthe.Resolution.t()) :: atom() | nil
  def resolve_type(%{__kind__: kind}, _resolution), do: object_for(kind)
  def resolve_type(_other, _resolution), do: nil

  defp object_for(:string), do: :string_value
  defp object_for(:int), do: :int_value
  defp object_for(:float), do: :float_value
  defp object_for(:boolean), do: :boolean_value
  defp object_for(:date), do: :date_value
  defp object_for(:datetime), do: :date_time_value
  defp object_for(:list), do: :list_value
  defp object_for(:group), do: :group_value
  defp object_for(:reference), do: :reference_value
  defp object_for(:media), do: :media_value
  defp object_for(:geolocation), do: :geolocation_value
  defp object_for(:json), do: :json_value
  defp object_for(_unknown), do: nil

  @desc """
  The value of one admin-defined custom field, by the kind its definition has.
  `name` is the field's name. Narrow with `... on FloatValue { value }`.
  """
  interface :custom_field_value do
    field :name, non_null(:string)
    resolve_type &__MODULE__.resolve_type/2
  end

  @desc "A text-like field: `string`, `text`, `url`, `select` or `user`."
  object :string_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, non_null(:string)
  end

  @desc "An `integer` field."
  object :int_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, non_null(:integer)
  end

  @desc "A `float` field."
  object :float_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, non_null(:float)
  end

  @desc "A `boolean` field."
  object :boolean_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, non_null(:boolean)
  end

  @desc "A `date` field."
  object :date_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, non_null(:date)
  end

  @desc "A `datetime` field."
  object :date_time_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, non_null(:datetime)
  end

  @desc """
  A `multiple` field: its items, in order, each a value of the field's item
  type. An item that does not match the definition is left out.
  """
  object :list_value do
    interface :custom_field_value
    field :name, non_null(:string)

    field :items, non_null(list_of(non_null(:custom_field_value))) do
      complexity &GraphqlLimits.list_complexity/3
    end
  end

  @desc """
  A `group` field: one object (or, in a `ListValue`, each row) of its
  sub-fields, as values.
  """
  object :group_value do
    interface :custom_field_value
    field :name, non_null(:string)

    field :fields, non_null(list_of(non_null(:custom_field_value))) do
      complexity &GraphqlLimits.list_complexity/3
    end
  end

  @desc """
  A `reference` field: the ids of the records it points at, in order. Only ids
  the reader may see are listed. Read the records through `references(field:)`.
  """
  object :reference_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :ids, non_null(list_of(non_null(:id)))
  end

  @desc "A `media` field, in the shape every delivery surface serves a media item."
  object :media_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :id, non_null(:id)
    field :url, :string
    field :alt, :string
    field :width, :integer
    field :height, :integer
    field :mime_type, :string
    field :focal, :media_focal
    field :variants, non_null(list_of(non_null(:media_variant)))
  end

  @desc "A media item's focal point, as fractions of its width and height."
  object :media_focal do
    field :x, non_null(:float)
    field :y, non_null(:float)
  end

  @desc "One derived rendition of a media item."
  object :media_variant do
    field :label, :string
    field :width, :integer
    field :height, :integer
    field :format, :string
    field :url, :string
    field :bytes, :integer
    field :cropped, :boolean
  end

  @desc "A `geolocation` field: a coordinate, with its optional place name and map zoom."
  object :geolocation_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :lat, non_null(:float)
    field :lng, non_null(:float)
    field :label, :string
    field :zoom, :integer
  end

  @desc """
  Anything that does not fit one scalar: a `computed` field, the other
  composite built-ins (`datetime_range`, `recurrence`) and a plugin type
  that does not name a GraphQL kind. `value` is the stored value as JSON.
  """
  object :json_value do
    interface :custom_field_value
    field :name, non_null(:string)
    field :value, :json_string
  end
end
