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
    * **media snapshots are re-taken**. A `:media` value is a snapshot of the
      library item when the document was saved (`KilnCMS.Media.Snapshot`) —
      possibly before its variants were derived, or before its focal point
      moved. The fired copy is rebuilt from the item as it is now, so the
      re-fire a media change triggers (`Changes.RefireMediaReferrers`) brings
      the artifact up to date. An item gone since keeps its stored snapshot.
      As with references, the stored value is not rewritten.
    * **unreadable reference targets are left out**. The stored snapshot was
      taken whatever state the target was in, a draft included, and an
      artifact is served to anyone at its URL. So the fired copy keeps only
      the snapshots an *anonymous* reader could read directly (the target's
      own read policy: published, public, not locked) — a list loses the
      item, a single-valued field reads as `nil` — exactly what `?expand=`
      and GraphQL `references` show (`KilnCMS.CMS.ReferenceSnapshots`). The
      target's publish re-fires this document (D13), which brings it back.
      A point-in-time read masks too: today's policy decides what may be
      shown, even of what was stored then.
    * **private fields are left out** (#2044, `KilnCMS.CMS.PrivateFields`),
      for every surface and every caller — visual editing fires a preview
      for anyone holding the page — and before computed fields read their
      siblings.
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
  alias KilnCMS.CMS.Checks.LinkEndsReadable
  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.PrivateFields
  alias KilnCMS.CMS.ReferenceSnapshots
  alias KilnCMS.Media.Snapshot

  @typedoc "A document's custom fields, resolved for firing."
  @type t :: %{values: map(), definitions: [struct()]}

  @doc """
  Resolve a document's custom fields for firing: the stored values with every
  computed field recomputed fresh, plus the definitions behind them.

  `body` is the document's plain text when the caller already has it (firing
  does), sparing a second walk of the block tree.

  `today:` is the date `today()` answers (`KilnCMS.CMS.Computed.Context`,
  "Pinning today"): the one the write that enqueued this fire pinned, when it
  did, so the artifact agrees with the value that write stored. Without one,
  the site's current date.
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
      #
      # A private field (#2044) goes too, before anything reads it: an artifact
      # is served to anyone at its URL, and a computed field derived from a
      # private value would publish what it computes.
      stored =
        stored
        |> Map.take(Enum.map(definitions, & &1.name))
        |> PrivateFields.drop(definitions)

      today = Keyword.get_lazy(opts, :today, &Computed.Context.today/0)

      values =
        definitions
        |> recompute(document, stored, body, today)
        |> refresh_references(definitions, Map.get(document, :org_id))
        |> refresh_media(definitions, Map.get(document, :org_id))

      %{values: values, definitions: definitions}
    else
      # Point-in-time: the stored map is the historical truth. Neither the
      # formulas nor the field registry of today may edit it — but what an
      # anonymous reader may see of it is today's question, so the unreadable
      # references are left out all the same (labels are not refreshed).
      # Private fields (#2044) are today's question too.
      values =
        stored
        |> PrivateFields.drop(definitions)
        |> mask_unreadable(Map.get(document, :org_id))

      %{values: values, definitions: definitions}
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

  defp recompute(definitions, document, stored, body, today) do
    case Enum.filter(definitions, &(&1.field_type == :computed)) do
      [] -> stored
      computed -> derive(computed, document, stored, body, today)
    end
  end

  defp derive(computed, document, stored, body, today) do
    # Every stored computed value is dropped before anything can read it: a
    # formula over another computed field sees that field derived fresh, in
    # the same dependency order as the write path (`Computed.derive/3`), never
    # the value stored by the last save.
    editable = Map.drop(stored, Enum.map(computed, & &1.name))
    context = Computed.Context.from_document(document, editable, today, body)

    Computed.derive(computed, context, editable)
  end

  # One read per distinct target type, ids only — not one per value. The
  # labels read are the anonymously readable targets', so the same read
  # decides both what is relabelled and what is left out.
  defp refresh_references(values, definitions, org_id) do
    names = for %{field_type: :reference, name: name} <- definitions, do: name

    case ReferenceSnapshots.snapshots(values) do
      [] ->
        values

      snapshots ->
        current =
          snapshots
          |> Enum.group_by(& &1["type"], & &1["id"])
          |> Enum.flat_map(fn {type, ids} -> readable_labels(org_id, type, Enum.uniq(ids)) end)
          |> Map.new()

        # Only a readable target is relabelled (a draft, gated, trashed or
        # purged one keeps the stored value, and `mask/2` then drops it), so
        # firing never copies an unpublished title into a public artifact.
        relabelled =
          values
          |> Map.take(names)
          |> Map.new(fn {name, v} -> {name, ReferenceSnapshots.relabel(v, current)} end)

        values
        |> Map.merge(relabelled)
        |> ReferenceSnapshots.mask(current |> Map.keys() |> MapSet.new())
    end
  end

  # One read for every media item the document's fields name.
  defp refresh_media(values, definitions, org_id) do
    names = for %{field_type: :media, name: name} <- definitions, do: name
    media = Map.take(values, names)

    case media |> Map.values() |> Enum.flat_map(&Snapshot.ids/1) do
      [] ->
        values

      ids ->
        items = Snapshot.load(org_id, ids)
        Map.merge(values, Map.new(media, fn {name, v} -> {name, Snapshot.refresh(v, items)} end))
    end
  end

  defp mask_unreadable(values, org_id) do
    case ReferenceSnapshots.ids(values) do
      [] -> values
      ids -> ReferenceSnapshots.mask(values, LinkEndsReadable.readable_ids(nil, org_id, ids))
    end
  end

  # Through the type's own list interface, so a dynamic type's read is scoped
  # to its definition. An unknown type (a target type deleted since the value
  # was saved) contributes nothing, and its values are left out.
  defp readable_labels(org_id, type, ids) do
    if KilnCMS.CMS.ContentTypes.get(type, org_id) do
      type
      |> KilnCMS.CMS.ContentTypes.list!(
        # As an anonymous reader, through the target type's own read policy
        # (published, public audience, not passphrase-locked): every artifact
        # consumer serves the body to anyone at the URL, so a target appears
        # in it only when anyone could read the target directly — the rule
        # `?expand=` (`KilnCMSWeb.ReferenceExpansion`) applies. Only id, slug
        # and title leave here.
        actor: nil,
        authorize?: true,
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
