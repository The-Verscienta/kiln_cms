defmodule KilnCMS.Verscienta.Transform do
  @moduledoc """
  Pure transforms from Directus items to KilnCMS shapes, driven by
  `KilnCMS.Verscienta.Mapping`. No database or network access — the
  `KilnCMS.Verscienta.Importer` performs the side effects using these results.
  """

  alias KilnCMS.Verscienta.Mapping

  @typedoc "A per-record plan the importer turns into a content record + media."
  @type plan :: %{
          directus_id: term(),
          type: atom(),
          title: String.t(),
          slug: String.t(),
          state_action: :publish | :archive | :draft,
          text_blocks: [map()],
          custom_fields: %{optional(String.t()) => term()},
          tag_refs: [{String.t(), String.t()}],
          featured_image: map() | nil,
          image_specs: [map()]
        }

  @typedoc "A cross-document relation to materialise as a ContentLink in pass 2."
  @type link_spec :: %{
          kind: atom(),
          target_collection: String.t(),
          target_directus_id: term(),
          position: non_neg_integer(),
          metadata: %{optional(String.t()) => term()}
        }

  # ── Field definitions (collection level) ────────────────────────────────

  @doc """
  Infer the `FieldDefinition`s needed for a collection's `custom_fields` by
  scanning every item, so a field's type is consistent across rows. Returns a
  list of `%{name, field_type}` (label/help left to the importer).
  """
  @spec field_definitions(Mapping.config(), [map()]) :: [%{name: String.t(), field_type: atom()}]
  def field_definitions(cfg, items) do
    consumed = Mapping.consumed_fields(cfg)

    items
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(consumed, &1))
    |> Enum.map(fn key ->
      values = items |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)
      %{name: key, field_type: infer_type(values)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  # All non-nil samples agree → that type; anything structured or mixed → :text.
  defp infer_type([]), do: :text

  defp infer_type(values) do
    cond do
      Enum.all?(values, &is_boolean/1) -> :boolean
      Enum.all?(values, &is_integer/1) -> :integer
      Enum.all?(values, &(is_integer(&1) or is_float(&1))) -> :float
      true -> :text
    end
  end

  # ── Per-record plan ─────────────────────────────────────────────────────

  @doc "Build the import plan for a single Directus item."
  @spec plan(Mapping.config(), map()) :: plan()
  def plan(cfg, item) do
    %{
      directus_id: item["id"],
      type: cfg.type,
      title: to_string(item[cfg.title_field] || item["title"] || item["name"] || "Untitled"),
      slug: slug(cfg, item),
      state_action: state_action(cfg.state_field, item),
      text_blocks: body_blocks(cfg, item),
      custom_fields: custom_fields(cfg, item),
      tag_refs: tag_refs(cfg, item),
      featured_image: featured_image(cfg, item),
      image_specs: image_specs(cfg, item)
    }
  end

  defp slug(cfg, item) do
    case item[cfg.slug_field] do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> item[cfg.title_field] |> to_string() |> Slug.slugify() || "item-#{item["id"]}"
    end
  end

  @doc false
  def state_action(nil, _item), do: :publish

  def state_action(_field, item) do
    case item |> Map.get("status") |> to_string() |> String.downcase() do
      "published" -> :publish
      "active" -> :publish
      "" -> :publish
      "archived" -> :archive
      _ -> :draft
    end
  end

  # Body blocks: each non-empty rich-text section → heading + rich_text.
  defp body_blocks(cfg, item) do
    cfg.body_sections
    |> Enum.flat_map(fn {field, label} ->
      case item[field] do
        html when is_binary(html) ->
          if blank_html?(html), do: [], else: [{:heading, label}, {:rich_text, html}]

        _ ->
          []
      end
    end)
    |> Enum.with_index()
    |> Enum.map(fn
      {{:heading, label}, i} -> %{type: :heading, content: label, data: %{"level" => 2}, order: i}
      {{:rich_text, html}, i} -> %{type: :rich_text, content: html, order: i}
    end)
  end

  defp blank_html?(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.trim()
    |> Kernel.==("")
  end

  # Everything not consumed structurally → custom_fields, JSON-encoding any
  # non-scalar so nothing is lost.
  defp custom_fields(cfg, item) do
    consumed = Mapping.consumed_fields(cfg)

    item
    |> Enum.reject(fn {k, v} -> MapSet.member?(consumed, k) or is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, encode_value(v)} end)
  end

  defp encode_value(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp encode_value(v), do: Jason.encode!(v)

  defp tag_refs(cfg, item) do
    Enum.flat_map(cfg.taxonomy_links, fn {field, namespace} ->
      item
      |> Map.get(field)
      |> List.wrap()
      |> Enum.map(&namespaced_tag(namespace, &1))
      |> Enum.reject(&is_nil/1)
    end)
  end

  # A taxonomy relation value may be an expanded item (map) or a bare id.
  defp namespaced_tag(namespace, %{} = related) do
    case related["slug"] || related["name"] || related["id"] do
      nil -> nil
      key -> {namespace, "#{namespace}-#{slugify_key(key)}"}
    end
  end

  defp namespaced_tag(namespace, id) when not is_nil(id), do: {namespace, "#{namespace}-#{id}"}
  defp namespaced_tag(_namespace, _), do: nil

  defp slugify_key(key), do: key |> to_string() |> Slug.slugify() || to_string(key)

  defp featured_image(cfg, item) do
    cond do
      cfg.featured_image && is_map(item[cfg.featured_image]) ->
        media_spec(item[cfg.featured_image])

      cfg.image_o2m ->
        {field, file_key} = cfg.image_o2m

        item
        |> Map.get(field)
        |> List.wrap()
        |> Enum.map(&Map.get(&1, file_key))
        |> Enum.find(&is_map/1)
        |> case do
          nil -> nil
          file -> media_spec(file)
        end

      true ->
        nil
    end
  end

  # O2M image children after the first (which becomes the featured image).
  defp image_specs(cfg, item) do
    case cfg.image_o2m do
      {field, file_key} ->
        item
        |> Map.get(field)
        |> List.wrap()
        |> Enum.map(&Map.get(&1, file_key))
        |> Enum.filter(&is_map/1)
        |> Enum.map(&media_spec/1)
        |> Enum.drop(1)

      _ ->
        []
    end
  end

  @doc """
  Build a `MediaItem` attrs map from a Directus file object, preferring the
  Cloudflare-offloaded URL the `cloudflare-offload` extension stores.
  """
  @spec media_spec(map()) :: map()
  def media_spec(file) do
    %{
      directus_id: file["id"],
      filename: file["filename_download"] || file["filename_disk"] || "image",
      content_type: file["type"] || "image/jpeg",
      url: file["cloudflare_url"] || file["url"],
      alt: file["title"] || file["description"],
      width: file["width"],
      height: file["height"]
    }
  end

  # ── Links (pass 2) ──────────────────────────────────────────────────────

  @doc "Cross-document relations for a single item, to become ContentLinks."
  @spec link_specs(Mapping.config(), map()) :: [link_spec()]
  def link_specs(cfg, item) do
    m2m_links(cfg, item) ++ o2m_links(cfg, item)
  end

  defp m2m_links(cfg, item) do
    Enum.flat_map(cfg.m2m_links, fn {field, kind, target} ->
      item
      |> Map.get(field)
      |> List.wrap()
      |> Enum.map(&extract_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.with_index()
      |> Enum.map(fn {id, pos} ->
        %{
          kind: kind,
          target_collection: target,
          target_directus_id: id,
          position: pos,
          metadata: %{}
        }
      end)
    end)
  end

  defp o2m_links(cfg, item) do
    Enum.flat_map(cfg.o2m_links, fn {field, kind, target, meta_fields} ->
      [ref_field | _] = meta_fields

      item
      |> Map.get(field)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, pos} ->
        case extract_id(child[ref_field]) do
          nil ->
            []

          target_id ->
            metadata =
              meta_fields
              |> Enum.reject(&(&1 == ref_field))
              |> Map.new(fn f -> {f, child[f]} end)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Map.new()

            [
              %{
                kind: kind,
                target_collection: target,
                target_directus_id: target_id,
                position: pos,
                metadata: metadata
              }
            ]
        end
      end)
    end)
  end

  # A relation value is either an expanded item (`%{"id" => ...}`) or a bare id.
  defp extract_id(%{} = m), do: m["id"]
  defp extract_id(id), do: id
end
