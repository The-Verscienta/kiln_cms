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
  @spec resolve(struct(), String.t() | nil) :: t()
  def resolve(document, body \\ nil) do
    definitions = definitions(document)
    stored = Map.get(document, :custom_fields) || %{}

    %{values: recompute(definitions, document, stored, body), definitions: definitions}
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
    # Computed fields never feed another computed field (one pass, exactly as on
    # the write path), so the context carries the editable values only —
    # dropping any stored computed value before it can be read.
    editable = Map.drop(stored, Enum.map(computed, & &1.name))
    context = Computed.Context.from_document(document, editable, body)

    Enum.reduce(computed, editable, &put_computed(&1, context, &2))
  end

  defp put_computed(definition, context, acc) do
    case Computed.evaluate(definition.compute || "", context) do
      nil -> acc
      value -> Map.put(acc, definition.name, value)
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

  # The definitions in scope: the owning dynamic type's (D17) or the compiled
  # content type's, under the document's own org (epic #336).
  defp definitions(%{org_id: org_id} = document) do
    case Map.get(document, :type_definition_id) do
      nil ->
        KilnCMS.CMS.field_definitions_for!(content_type(document),
          authorize?: false,
          tenant: org_id
        )

      id ->
        KilnCMS.CMS.field_definitions_for_definition!(id, authorize?: false, tenant: org_id)
    end
  end

  defp definitions(_document), do: []

  defp content_type(%module{}), do: module.__kiln_content_type__()
end
