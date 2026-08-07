defmodule KilnCMS.CMS.ContentCopy do
  @moduledoc """
  Shared mechanics for copying one content record's authored payload into a
  **brand-new** record.

  Two features clone content: the one-click translation
  (`KilnCMS.CMS.Translations`, into a new locale) and the duplicate action
  (`KilnCMS.CMS.Duplication`, into a new draft of the same locale). They differ
  in what identifies the copy — a translation keeps the slug and changes the
  locale, a duplicate keeps the locale and regenerates the slug — but the
  payload in between is the same, and so are the parts that are easy to get
  wrong:

    * **blocks** must go back through the union's storage shape so the create
      action re-casts (and re-sanitizes) them, minus their stable ids — at
      *every* depth, since `columns` children carry ids of their own — so the
      copy gets fresh ones;
    * **tags** are a `manage_relationship` argument on `:create`, not an
      attribute, so they travel as an id list — and the load that reads them
      must project ids only, or one click drags every tag's full row into the
      caller's heap.

  Everything here is payload-only. Workflow (`state`, schedules), delivery
  bookkeeping (published version, artifacts) and history start fresh on the
  copy, by virtue of simply not being copied. Curated **related content** is
  not here either: those rows carry a per-link payload (`kind`, `position`,
  `label`, `metadata`) that the `related_<type>_ids` argument would flatten, so
  `KilnCMS.CMS.Duplication` clones the `ContentLink` rows themselves.
  """

  alias KilnCMS.CMS.Tag

  # The authored content attributes shared by every clone. Deliberately absent:
  # `slug`/`locale` (each caller decides — they're what identifies the copy),
  # `canonical_url` (points at the *source*'s canonical URL, never the copy's),
  # `path_alias` (re-derived from the type's alias pattern), and every workflow
  # / scheduling column.
  @content_attrs [
    :title,
    :excerpt,
    :seo_title,
    :seo_description,
    :seo_keywords,
    :seo_image,
    :audience,
    :custom_fields,
    :category_id,
    :featured_image_id
  ]

  @doc """
  The authored content attributes every clone carries (see the module doc for
  what is deliberately excluded).
  """
  @spec content_attrs() :: [atom()]
  def content_attrs, do: @content_attrs

  @doc """
  The load a caller must request so `tag_ids/1` sees a real list rather than
  `%Ash.NotLoaded{}` — projected to ids, because that is all it reads.
  """
  @spec tag_load() :: keyword()
  def tag_load, do: [tags: Ash.Query.select(Tag, [:id])]

  @doc """
  `record`'s values for `keys`, as create-action attrs. `nil` values are
  dropped rather than sent, so the create action's own defaults apply.
  """
  @spec take(struct(), [atom()]) :: map()
  def take(record, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.get(record, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  `record`'s block tree, dumped back to the union's storage shape so the create
  action re-casts it, with every block's stable id stripped so the copy mints
  fresh ones.
  """
  @spec dump_blocks(struct()) :: [map()]
  def dump_blocks(record) do
    attribute = Ash.Resource.Info.attribute(record.__struct__, :blocks)

    {:ok, dumped} =
      Ash.Type.dump_to_embedded(attribute.type, record.blocks || [], attribute.constraints)

    Enum.map(dumped, &strip_ids/1)
  end

  # Drop `id` from every block-shaped map in the tree, at any depth. The union
  # dumps nested (`%{"type" => …, "value" => %{id: …, _type: "columns", …}}`)
  # and a `columns` block holds its children as raw maps that carry ids of their
  # own — a top-level-only strip would leave the copy sharing nested block ids
  # with its source. `_type` is what marks a map as a block, so ordinary maps in
  # a block field (a media reference, a custom-field map) keep their `id`.
  #
  # Key shapes are mixed on purpose: `dump_to_embedded` emits atom keys for the
  # block's own attributes, while nested children keep the string keys they were
  # cast from.
  defp strip_ids(%{} = map) when not is_struct(map) do
    map
    |> drop_block_id()
    |> Map.new(fn {key, value} -> {key, strip_ids(value)} end)
  end

  defp strip_ids(list) when is_list(list), do: Enum.map(list, &strip_ids/1)
  defp strip_ids(other), do: other

  defp drop_block_id(map) do
    if Map.has_key?(map, :_type) or Map.has_key?(map, "_type"),
      do: Map.drop(map, ["id", :id]),
      else: map
  end

  @doc "The source's tag ids, for the create action's `tag_ids` argument."
  @spec tag_ids(struct()) :: [Ash.UUID.t()]
  def tag_ids(record) do
    case Map.get(record, :tags) do
      tags when is_list(tags) -> Enum.map(tags, & &1.id)
      _not_loaded -> []
    end
  end
end
