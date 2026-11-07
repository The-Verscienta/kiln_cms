defmodule KilnCMSWeb.Graphql.CustomFields do
  @moduledoc """
  Resolvers for the typed custom-field readers on every content type
  (#2290): `customString` / `customInt` / `customFloat` / `customBoolean` /
  `customDate` / `customDateTime` (`name:`) and `fields(names:)`. See
  `KilnCMSWeb.Graphql.ContentRecord.Notation.custom_field_accessors/0` and
  `KilnCMSWeb.Graphql.CustomFieldValues`.

  ## What is served

  The record's own stored `custom_fields`, read against the type's **current**
  definitions. A value is served only when its definition exists and its kind
  (`KilnCMS.CMS.FieldKind`) is the one asked for and the stored value fits it.
  Anything else (an unknown, renamed or deleted name, a field of another kind,
  a legacy value that no longer fits, a blank) is `null`, or left out of
  `fields`. Nothing here raises for a name the site does not have.

  A `localization: :fallback` field does **not** inherit along the locale
  chain here: the typed layer serves what the record itself stores, as
  `customFields` does.

  ## Batching

  AshGraphql selects only the attributes a document names, so a document that
  asks for `customFloat(name: "price")` alone leaves `custom_fields`,
  `type_definition_id` and `org_id` unloaded on the parent. Every parent of one
  resource is therefore resolved in one Absinthe batch:

    * parents that already carry those keys are used as they are;
    * the others are read again **in one query, as the request's actor**;
    * the definitions are read once per scope (`{resource,
      type_definition_id, org_id}`), as `KilnCMS.CMS.Calculations.CustomFieldsPlain`
      does.

  ## Who sees what

  The re-read must be made as the request's actor, never `authorize?: false`
  or a system actor. `KilnCMS.CMS.Preparations.MaskPrivateFields` leaves
  private fields out of a read only for a real actor below editor (or none),
  and it is that mask this module relies on: a private field is simply not in
  the map an anonymous reader or a viewer gets, so it reads as unknown. There
  is no second predicate to keep in step.
  """

  import Absinthe.Resolution.Helpers, only: [batch: 3]

  require Ash.Query

  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.FieldKind
  alias KilnCMSWeb.Graphql.References
  alias KilnCMSWeb.GraphqlLimits

  # Groups inside groups are not offered by the editor, but a definition can
  # be written through the API; the cap bounds what one value can build.
  @max_group_depth 3

  @doc "Resolver for `customString(name:)`."
  def custom_string(parent, args, resolution), do: scalar(parent, args, resolution, :string)
  @doc "Resolver for `customInt(name:)`."
  def custom_int(parent, args, resolution), do: scalar(parent, args, resolution, :int)
  @doc "Resolver for `customFloat(name:)`."
  def custom_float(parent, args, resolution), do: scalar(parent, args, resolution, :float)
  @doc "Resolver for `customBoolean(name:)`."
  def custom_boolean(parent, args, resolution), do: scalar(parent, args, resolution, :boolean)
  @doc "Resolver for `customDate(name:)`."
  def custom_date(parent, args, resolution), do: scalar(parent, args, resolution, :date)

  @doc "Resolver for `customDateTime(name:)`."
  def custom_date_time(parent, args, resolution),
    do: scalar(parent, args, resolution, :datetime)

  @doc "Resolver for `fields(names:)`."
  def fields(parent, %{names: names}, resolution) do
    if length(names) > GraphqlLimits.max_custom_field_names() do
      {:error, "fields: at most #{GraphqlLimits.max_custom_field_names()} names per field"}
    else
      names = Enum.uniq(names)

      with_view(parent, resolution, fn
        nil -> {:ok, []}
        view -> {:ok, for(name <- names, value = value_of(view, name), do: value)}
      end)
    end
  end

  defp scalar(parent, %{name: name}, resolution, kind) do
    with_view(parent, resolution, fn
      nil ->
        {:ok, nil}

      view ->
        with %{definition: %{multiple: false} = definition} <- view.fields[name],
             ^kind <- FieldKind.kind_for(definition),
             %{value: value} <- build(definition, Map.get(view.values, name), 0) do
          {:ok, value}
        else
          _mismatch -> {:ok, nil}
        end
    end)
  end

  defp value_of(view, name) do
    case view.fields[name] do
      %{definition: definition} -> build(definition, Map.get(view.values, name), 0)
      nil -> nil
    end
  end

  # -- Values -----------------------------------------------------------------

  # `nil` for a value that is absent or does not fit the definition.
  defp build(_definition, nil, _depth), do: nil

  defp build(%{multiple: true} = definition, raw, depth) when is_list(raw) do
    items = for item <- raw, value = build_item(definition, item, depth), do: value
    %{__kind__: :list, name: definition.name, items: items}
  end

  defp build(%{multiple: true}, _raw, _depth), do: nil
  defp build(definition, raw, depth), do: build_item(definition, raw, depth)

  defp build_item(_definition, nil, _depth), do: nil

  defp build_item(definition, raw, depth) do
    name = definition.name
    build_kind(FieldKind.item_kind_for(definition), definition, name, raw, depth)
  end

  defp build_kind(:string, _d, name, v, _depth) when is_binary(v),
    do: %{__kind__: :string, name: name, value: v}

  defp build_kind(:int, _d, name, v, _depth) when is_integer(v),
    do: %{__kind__: :int, name: name, value: v}

  defp build_kind(:float, _d, name, v, _depth) when is_number(v),
    do: %{__kind__: :float, name: name, value: v * 1.0}

  defp build_kind(:boolean, _d, name, v, _depth) when is_boolean(v),
    do: %{__kind__: :boolean, name: name, value: v}

  defp build_kind(:date, _d, name, v, _depth), do: date(name, v)
  defp build_kind(:datetime, _d, name, v, _depth), do: datetime(name, v)
  defp build_kind(:group, d, _name, v, depth) when is_map(v), do: group(d, v, depth)
  defp build_kind(:reference, _d, name, v, _depth), do: reference(name, v)
  defp build_kind(:media, _d, name, v, _depth), do: media(name, v)
  defp build_kind(:geolocation, _d, name, v, _depth), do: geolocation(name, v)
  defp build_kind(:json, _d, name, v, _depth), do: %{__kind__: :json, name: name, value: v}
  defp build_kind(_kind, _d, _name, _v, _depth), do: nil

  # `lat`/`lng` are always floats once stored (`Geolocation.cast/2`), but the
  # column is plain jsonb: an out-of-range or non-numeric coordinate, or a
  # `label`/`zoom` of another type, is a legacy shape and reads as absent
  # rather than failing the whole document.
  defp geolocation(name, %{"lat" => lat, "lng" => lng} = raw)
       when is_number(lat) and is_number(lng) and lat >= -90 and lat <= 90 and lng >= -180 and
              lng <= 180 do
    %{
      __kind__: :geolocation,
      name: name,
      lat: lat * 1.0,
      lng: lng * 1.0,
      label: if(is_binary(raw["label"]), do: raw["label"]),
      zoom: if(is_integer(raw["zoom"]), do: raw["zoom"])
    }
  end

  defp geolocation(_name, _raw), do: nil

  defp date(name, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> %{__kind__: :date, name: name, value: date}
      {:error, _reason} -> nil
    end
  end

  defp date(_name, _value), do: nil

  defp datetime(name, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        %{__kind__: :datetime, name: name, value: datetime}

      {:error, _reason} ->
        # Stored without an offset: read as UTC, as the rest of the app does.
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          %{__kind__: :datetime, name: name, value: datetime}
        else
          _invalid -> nil
        end
    end
  end

  defp datetime(_name, _value), do: nil

  defp group(definition, row, depth) when depth < @max_group_depth do
    subfields =
      case Map.get(definition, :group_fields) do
        subs when is_list(subs) -> subs
        _not_loaded -> []
      end

    values =
      for sub <- subfields,
          value = build(sub, Map.get(row, sub.name), depth + 1),
          do: value

    %{__kind__: :group, name: definition.name, fields: values}
  end

  defp group(_definition, _row, _depth), do: nil

  defp reference(name, raw) do
    case ids(raw) do
      [] -> nil
      ids -> %{__kind__: :reference, name: name, ids: ids}
    end
  end

  defp ids(%{"id" => id}) when is_binary(id), do: [id]
  defp ids(list) when is_list(list), do: Enum.flat_map(list, &ids/1)
  defp ids(_other), do: []

  # The stored value is the `KilnCMS.Media.Snapshot` shape, so it is served
  # as stored, with only its known keys.
  defp media(name, %{"id" => id} = snapshot) when is_binary(id) do
    %{
      __kind__: :media,
      name: name,
      id: id,
      url: snapshot["url"],
      alt: snapshot["alt"],
      width: snapshot["width"],
      height: snapshot["height"],
      mime_type: snapshot["mime_type"],
      focal: focal(snapshot["focal"]),
      variants: variants(snapshot["variants"])
    }
  end

  defp media(_name, _raw), do: nil

  defp focal(%{"x" => x, "y" => y}) when is_number(x) and is_number(y),
    do: %{x: x * 1.0, y: y * 1.0}

  defp focal(_other), do: nil

  defp variants(list) when is_list(list) do
    for %{} = variant <- list do
      %{
        label: variant["label"],
        width: variant["width"],
        height: variant["height"],
        format: variant["format"],
        url: variant["url"],
        bytes: variant["bytes"],
        cropped: variant["cropped"]
      }
    end
  end

  defp variants(_other), do: []

  # -- Batched views ----------------------------------------------------------

  # Runs `post` with the parent's view (`nil` when the parent could not be
  # read), once every parent of its resource in the document has been seen.
  defp with_view(parent, resolution, post) do
    key = {parent.__struct__, actor(resolution), tenant(resolution)}

    batch({__MODULE__, :load_views, key}, parent, fn views ->
      post.(Map.get(views, parent.id))
    end)
  end

  @doc false
  # Absinthe batch function: `%{id => %{values: custom_fields, fields: %{name =>
  # %{definition: …}}}}` for every parent of one resource.
  def load_views({resource, actor, tenant}, parents) do
    keys = needed_keys(resource)
    parents = Enum.uniq_by(parents, & &1.id)

    {ready, missing} =
      Enum.split_with(parents, fn parent -> Enum.all?(keys, &loaded?(parent, &1)) end)

    records = ready ++ reread(resource, missing, keys, actor, tenant)

    definitions =
      records
      |> Enum.map(&scope(&1, tenant))
      |> Enum.uniq()
      |> Map.new(fn {_resource, type_definition_id, org_id} = scope ->
        {scope, top_level(ApplyCustomFields.definitions(resource, type_definition_id, org_id))}
      end)

    Map.new(records, fn record ->
      values =
        case record.custom_fields do
          values when is_map(values) and not is_struct(values) -> values
          _none -> %{}
        end

      {record.id, %{values: values, fields: Map.fetch!(definitions, scope(record, tenant))}}
    end)
  end

  defp needed_keys(resource) do
    [
      :custom_fields
      | Enum.filter([:org_id, :type_definition_id], &Ash.Resource.Info.attribute(resource, &1))
    ]
  end

  defp loaded?(record, key), do: not match?(%Ash.NotLoaded{}, Map.get(record, key))

  defp reread(_resource, [], _keys, _actor, _tenant), do: []

  defp reread(resource, parents, keys, actor, tenant) do
    ids = Enum.map(parents, & &1.id)

    # One read per resource, AS THE REQUEST'S ACTOR. Do not make this
    # `authorize?: false` or a system actor: `MaskPrivateFields` only masks a
    # read made for a real actor below editor, and it is what keeps a private
    # field out of the map this module serves. These parents were just read
    # by the same actor, so the read cannot show more than the document does.
    query =
      resource
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id | keys])

    References.read_records(resource, query, actor: actor, tenant: tenant)
  end

  defp scope(%resource{} = record, tenant) do
    {resource, Map.get(record, :type_definition_id), Map.get(record, :org_id) || tenant}
  end

  # The fields a document is read by: top-level definitions, by name. A
  # group's sub-fields hang off it (`group_fields`), a reference's link fields
  # are not values of the record.
  defp top_level(definitions) do
    for %{group_of_id: nil, link_of_id: nil} = definition <- definitions,
        into: %{},
        do: {definition.name, %{definition: definition}}
  end

  defp actor(%{context: context}), do: Map.get(context, :actor)

  defp tenant(%{context: context}) do
    case Map.get(context, :tenant) do
      %{id: id} -> id
      other -> other
    end
  end
end
