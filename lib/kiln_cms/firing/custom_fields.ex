defmodule KilnCMS.Firing.CustomFields do
  @moduledoc """
  The custom-field half of a fired artifact: the admin-defined values a
  document carries (`KilnCMS.CMS.FieldDefinition`), resolved once per fire and
  projected onto the surfaces that can express them.

  Two things happen here that can't happen at write time:

    * **computed fields are recomputed** (#429). A stored computed value is a
      snapshot of the formula *as it was when the record was last saved*;
      without this, editing a formula would only ever reach content that
      happens to be re-saved afterwards. Recomputing at fire time means a
      formula change reaches published output on the next fire, and no stale
      derived value rides out on an artifact.
    * **reference labels are read fresh**. A `:reference` value stores a
      `%{"id", "type", "slug", "title"}` snapshot taken when the referrer was
      saved; the target can be renamed since. The fired copy carries the
      target's *current* slug and title when the target is published, so the
      re-fire a rename triggers (decision D13, `KilnCMS.Firing.References`)
      actually changes the artifact. The stored snapshot is not rewritten, and
      its shape is unchanged — only the two label values are refreshed.
    * **geolocation fields become structured data** (#428). A
      `%{"lat", "lng"}` value is a schema.org `Place` with `GeoCoordinates`,
      contributed to the document's `contentLocation` — a property
      `CreativeWork` (and so every `@type` KilnCMS fires) actually defines.

  `resolve/2` is called once per `KilnCMS.Firing.Engine.fire/2` and its result
  feeds every surface, so composing four surfaces costs one definitions read.
  That read is `authorize?: false` under the document's own org: registry
  metadata for a document already resolved for delivery, and firing runs
  outside any actor's session.
  """
  alias KilnCMS.CMS.Computed

  @typedoc "A document's custom fields, resolved for firing."
  @type t :: %{values: map(), definitions: [struct()]}

  @doc """
  Resolve a document's custom fields for firing: the stored values with every
  computed field recomputed fresh, plus the definitions behind them.

  `body` is the document's plain text when the caller already has it (firing
  does), sparing a second walk of the block tree.
  """
  @spec resolve(struct(), String.t() | nil, keyword()) :: t()
  def resolve(document, body \\ nil, opts \\ []) do
    definitions = definitions(document)
    stored = Map.get(document, :custom_fields) || %{}

    if Keyword.get(opts, :recompute?, true) do
      # Project onto the *current* definitions, exactly as the write path does
      # (`ApplyCustomFields` reduces over definitions into a fresh map). Taking
      # the stored map whole would keep publishing a value whose definition has
      # since been deleted or renamed — the row survives the destroy, and an
      # ordinary title-only edit never rewrites it.
      stored = Map.take(stored, Enum.map(definitions, & &1.name))

      values =
        definitions
        |> recompute(document, stored, body)
        |> refresh_references(definitions, Map.get(document, :org_id))

      %{values: values, definitions: definitions}
    else
      # Point-in-time: the stored map is the historical truth. Neither the
      # formulas nor the field registry of today may edit it.
      %{values: stored, definitions: definitions}
    end
  end

  @doc """
  The schema.org `contentLocation` for the resolved geolocation fields, or
  `nil` when there are none.

  One `Place` per populated geolocation field — a bare map for a single place
  rather than a one-element array, which is noise in the graph. The place's
  `name` is the value's own label, falling back to the field's label, so a
  consumer always has something to render.
  """
  @spec content_location(t()) :: map() | [map()] | nil
  def content_location(%{values: values, definitions: definitions}) do
    definitions
    |> Enum.filter(&(&1.field_type == :geolocation))
    |> Enum.flat_map(&place(&1, Map.get(values, &1.name)))
    |> case do
      [] -> nil
      [place] -> place
      places -> places
    end
  end

  defp recompute(definitions, document, stored, body) do
    case Enum.filter(definitions, &(&1.field_type == :computed)) do
      [] -> stored
      computed -> derive(computed, document, stored, body)
    end
  end

  defp derive(computed, document, stored, body) do
    # Every stored computed value is dropped before anything can read it: a
    # formula over another computed field sees that field derived fresh, in
    # the same dependency order as the write path (`Computed.derive/3`), never
    # the value stored by the last save.
    editable = Map.drop(stored, Enum.map(computed, & &1.name))
    context = Computed.Context.from_document(document, editable, body)

    Computed.derive(computed, context, editable)
  end

  # One read per distinct target type, ids only — not one per value.
  defp refresh_references(values, definitions, org_id) do
    names = for %{field_type: :reference, name: name} <- definitions, do: name

    snapshots =
      values
      |> Map.take(names)
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.filter(&snapshot?/1)

    case snapshots do
      [] ->
        values

      snapshots ->
        current =
          snapshots
          |> Enum.group_by(& &1["type"], & &1["id"])
          |> Enum.flat_map(fn {type, ids} -> published_labels(org_id, type, Enum.uniq(ids)) end)
          |> Map.new()

        relabelled =
          values |> Map.take(names) |> Map.new(fn {name, v} -> {name, relabel(v, current)} end)

        Map.merge(values, relabelled)
    end
  end

  defp snapshot?(%{"id" => id, "type" => type}) when is_binary(id) and is_binary(type),
    do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp snapshot?(_value), do: false

  defp relabel(list, current) when is_list(list), do: Enum.map(list, &relabel(&1, current))

  defp relabel(%{"id" => id} = snapshot, current) when is_map_key(current, id),
    do: Map.merge(snapshot, Map.fetch!(current, id))

  # Not published (a draft, trashed, purged) or not a snapshot at all: keep the
  # stored value. A label is only refreshed from a row a reader may already
  # see — firing never copies an unpublished title into a public artifact.
  defp relabel(value, _current), do: value

  # Through the type's own list interface, so a dynamic type's read is scoped
  # to its definition. An unknown type (a target type deleted since the value
  # was saved) contributes nothing, and its values keep their stored labels.
  defp published_labels(org_id, type, ids) do
    if KilnCMS.CMS.ContentTypes.get(type, org_id) do
      type
      |> KilnCMS.CMS.ContentTypes.list!(
        # authorize?: false — firing has no actor (see `system_actor/0`); the
        # read is tenant-scoped, published rows only, and only slug/title
        # leave here — the same stance as `References.load_published/3`.
        authorize?: false,
        tenant: org_id,
        query: [filter: [id: [in: ids], state: :published], select: [:id, :slug, :title]]
      )
      |> Enum.map(&{&1.id, %{"slug" => &1.slug, "title" => &1.title}})
    else
      []
    end
  end

  defp place(definition, %{"lat" => lat, "lng" => lng} = value)
       when is_number(lat) and is_number(lng) do
    name =
      case Map.get(value, "label") do
        label when is_binary(label) and label != "" -> label
        _unlabelled -> definition.label
      end

    [
      %{
        "@type" => "Place",
        "name" => name,
        "geo" => %{"@type" => "GeoCoordinates", "latitude" => lat, "longitude" => lng}
      }
    ]
  end

  defp place(_definition, _value), do: []

  # Firing has no request actor (see `KilnCMS.Firing.Engine`). `FieldDefinition`
  # admits it for reads (#1402) — the field schema is what turns a document's
  # `custom_fields` values into JSON-LD. Defining a field stays admin-only.
  defp system_actor, do: KilnCMS.SystemActor.new(:firing)

  # The definitions in scope: the owning dynamic type's (D17) or the compiled
  # content type's, under the document's own org (epic #336).
  defp definitions(%{org_id: org_id} = document) do
    case {Map.get(document, :type_definition_id), content_type(document)} do
      {nil, nil} ->
        # A dynamic entry whose type definition isn't set yet, or a resource
        # built outside the Content macro: no field schema to resolve.
        []

      {nil, type} ->
        KilnCMS.CMS.field_definitions_for!(type, actor: system_actor(), tenant: org_id)

      {id, _type} ->
        KilnCMS.CMS.field_definitions_for_definition!(id, actor: system_actor(), tenant: org_id)
    end
  end

  defp definitions(_document), do: []

  # Only compiled types export `__kiln_content_type__/0` — the dynamic entry
  # tier deliberately does not (see the Content macro's `markers`). Guard the
  # call the way `Engine.document_type/1` and every other consumer does, or
  # firing a document without the hook raises `UndefinedFunctionError`:
  # `FireWorker` would swallow it and never write artifacts, and `RefireWorker`
  # has no rescue at all, leaving referrer artifacts permanently stale.
  defp content_type(%module{}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__kiln_content_type__, 0) do
      module.__kiln_content_type__()
    end
  end
end
