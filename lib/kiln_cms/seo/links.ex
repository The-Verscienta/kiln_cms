defmodule KilnCMS.Seo.Links do
  @moduledoc """
  Internal-link suggestions for the content editor (#377): other pages on this
  site worth linking to from the one being edited.

  ## Two legs, because one would leave most installs with nothing

  `KilnCMS.Search.Related.related_documents/2` is the good answer — nearest
  block embeddings, already org-scoped and published-only. But it returns `[]`
  whenever semantic search is disabled, and semantic search is **off by
  default**. For a related-content API that degradation is correct; for a link
  *suggester* it would mean the feature silently doesn't exist on a default
  install.

  So when the semantic leg is unavailable or comes back empty, this falls back
  to a keyword sweep over the focus keyphrase (or the title) via
  `KilnCMS.Search.global/2` — the same "degrade to keyword" posture
  `KilnCMS.Ask` takes. `:source` on each suggestion says which leg produced it.

  ## Read-only, deliberately

  This returns a list. It does **not** insert anything into the body, and that
  is a design decision rather than a missing feature: rich text lives in a
  Portable Text tree mirrored into a TipTap editor under `phx-update="ignore"`,
  and under the collaborative-editing prototype the text is a shared Y.Doc that
  only the elected persister writes. A server-side tree mutation would have to
  split a span, mint a `markDefs` key, and force the document back into TipTap
  — which means remounting the editor and discarding the author's cursor, undo
  history and CRDT sync. Insertion, if it is ever built, belongs on the client
  as a TipTap command at the current selection.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.Search
  alias KilnCMS.Search.Related

  @type suggestion :: %{
          type: String.t(),
          id: Ash.UUID.t(),
          title: String.t() | nil,
          slug: String.t(),
          path: String.t(),
          distance: float() | nil,
          source: :semantic | :keyword
        }

  @default_limit 5

  @doc """
  Pages worth linking to from `record`.

  Options: `:limit` (default #{@default_limit}), `:actor`, `:tenant`, and
  `:exclude_paths` — paths the body already links to, so the panel doesn't
  suggest a link that is already there.
  """
  @spec suggest(struct(), keyword()) :: [suggestion()]
  def suggest(record, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    exclude = opts |> Keyword.get(:exclude_paths, []) |> MapSet.new()

    record
    |> candidates(limit)
    |> Enum.reject(&drop?(&1, record, exclude))
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  # Not the page being edited, resolvable to a real URL, and not already linked.
  defp drop?(suggestion, record, exclude) do
    suggestion.id == record.id or
      suggestion.path in [nil, ""] or
      MapSet.member?(exclude, suggestion.path)
  end

  # Over-fetch on both legs: self, already-linked and unresolvable-path
  # candidates are all filtered afterwards.
  defp candidates(record, limit) do
    case semantic(record, limit) do
      [] -> keyword(record, limit)
      results -> results
    end
  end

  defp semantic(record, limit) do
    if Search.semantic?() do
      record
      |> Related.related_documents(limit: limit * 3)
      |> Enum.map(&Map.put(&1, :source, :semantic))
    else
      []
    end
  end

  defp keyword(record, limit) do
    case query_for(record) do
      "" ->
        []

      query ->
        query
        |> Search.global(
          tenant: record.org_id,
          authorize?: false,
          limit: limit * 2,
          locale: record.locale
        )
        |> content_hits()
        |> Enum.flat_map(&entry(&1, record.org_id))
    end
  end

  # The focus keyphrase is what the author says this page is about; the title
  # is the fallback when they haven't set one.
  defp query_for(record) do
    case KilnCMS.Slug.focus_keyphrase(Map.get(record, :seo_keywords)) do
      "" -> record |> Map.get(:title) |> to_string() |> String.trim()
      keyphrase -> keyphrase
    end
  end

  # Content sections only. `global/2` also returns media, categories and tags,
  # none of which are pages you would link a paragraph to.
  defp content_hits(sections) do
    keys = Enum.map(ContentTypes.all(), & &1.section) ++ [:entries]

    sections
    |> Map.take(keys)
    |> Enum.flat_map(fn {_section, hits} -> hits end)
  end

  # Only pages a reader can actually open. `Search.global/2` runs with
  # `authorize?: false` and happily returns drafts and audience-gated records;
  # both would invite the author to link a public page at a URL the reader
  # can't follow. This mirrors the delivery boundary in
  # `Slugs.find_published_by_alias/3` — published AND public.
  defp entry(%{state: state}, _org_id) when state != :published, do: []
  defp entry(%{audience: audience}, _org_id) when audience != :public, do: []

  defp entry(doc, org_id) do
    type = KilnCMS.Firing.Engine.public_type(doc)

    case ContentTypes.get(type, org_id) do
      nil ->
        []

      ct ->
        [
          %{
            type: type,
            id: doc.id,
            title: doc.title,
            slug: doc.slug,
            path: Slugs.public_path_for(ct, doc),
            # Keyword relevance and cosine distance aren't the same scale, so
            # rather than inventing a comparable number the keyword leg reports
            # none and callers rely on order.
            distance: nil,
            source: :keyword
          }
        ]
    end
  end
end
