defmodule KilnCMS.Organize.Health do
  @moduledoc """
  Taxonomy health (#1596): what is wrong with the vocabulary itself, and with
  the library's links.

    * **Unused** and **single-use** terms — tags and categories with 0 or 1
      live uses (`KilnCMS.Organize.Terms.usage/2`: trashed content does not
      count, and counts are read as the actor).
    * **Near-duplicate tags** — pairs of tags whose stored *name* vectors sit
      within `KilnCMS.Search.near_duplicate_term_threshold/0`: "colour" and
      "color", "tutorial" and "tutorials" (abbreviations such as "JS" sit
      among related-but-distinct pairs and are missed by design — see the
      threshold's measurement). Tags only (categories have no vector),
      stored vectors only (never infers; `missing_vectors` says how many tags
      the check could not see yet). All pairs in memory over at most
      `bound(:term_limit)` (500) tags — measured at that bound, ~330 ms on a
      lean build.
    * **Nothing links here** — published documents (at most
      `bound(:inbound_limit)`, 300, newest first) that no `KilnCMS.CMS.ContentLink`
      edge targets: no curated related link, no `:reference` custom field
      (#1594). One edge read for the whole set. A self-link does not count.
      An edge from a **trashed** source still counts: `ContentLinks` keeps a
      trashed record's outgoing edges until it is purged (a restore brings
      them back), so a document linked only from the trash reads as linked —
      the console caption says so.
      This is the *content-graph* half of orphan detection; whether a menu
      links a document is the structure view's question (#1597, PR #1895's
      `Menus.linked_content_ids/1`), deliberately not redefined here.

  Empty when semantic search is off — including the parts that need no
  vectors, per the maintainer's "on a default install this whole workstream is
  invisible" (#1596). That is recorded as an open question there.
  """
  alias KilnCMS.CMS
  alias KilnCMS.Organize
  alias KilnCMS.Organize.Candidates
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Organize.Vectors

  @typedoc "The report."
  @type t :: %{
          unused: [Terms.t()],
          single_use: [Terms.t()],
          near_duplicates: [%{a: Terms.t(), b: Terms.t(), distance: float()}],
          missing_vectors: non_neg_integer(),
          terms_truncated?: boolean(),
          unlinked: [Candidates.t()],
          unlinked_considered: non_neg_integer(),
          unlinked_truncated?: boolean()
        }

  @empty %{
    unused: [],
    single_use: [],
    near_duplicates: [],
    missing_vectors: 0,
    terms_truncated?: false,
    unlinked: [],
    unlinked_considered: 0,
    unlinked_truncated?: false
  }

  @doc "The health report for the actor. Empty when semantic search is off."
  @spec report(term(), term()) :: t()
  def report(org, actor) do
    if Organize.enabled?(), do: compute(org, actor), else: @empty
  end

  defp compute(org, actor) do
    usage = Terms.usage(org, actor)
    tags = Terms.tags(org, actor)
    vectors = Terms.tag_vectors(org, tags)
    limit = Organize.bound(:term_limit)

    %{rows: published, truncated?: unlinked_truncated?} =
      Candidates.bounded(org, actor, limit: Organize.bound(:inbound_limit), state: :published)

    %{
      unused: for({term, 0} <- usage, do: term),
      single_use: for({term, 1} <- usage, do: term),
      near_duplicates: near_duplicates(tags, vectors),
      missing_vectors: length(tags) - map_size(vectors),
      terms_truncated?:
        length(tags) >= limit or
          Enum.count(usage, &(elem(&1, 0).kind == :category)) >= limit,
      unlinked: unlinked(org, actor, published),
      unlinked_considered: length(published),
      unlinked_truncated?: unlinked_truncated?
    }
  end

  @doc """
  Pairs of `tags` whose stored name vectors (`vectors`, `%{id => [float]}`)
  sit within the near-duplicate threshold, closest first.
  """
  @spec near_duplicates([Terms.t()], %{Ash.UUID.t() => [float()]}) ::
          [%{a: Terms.t(), b: Terms.t(), distance: float()}]
  def near_duplicates(tags, vectors) do
    threshold = KilnCMS.Search.near_duplicate_term_threshold()
    indexed = for tag <- tags, v = Map.get(vectors, tag.id), do: {tag, Vectors.normalize(v)}

    indexed
    |> pairs()
    |> Enum.flat_map(fn {{a, va}, {b, vb}} ->
      distance = 1.0 - Vectors.dot(va, vb)
      if distance <= threshold, do: [%{a: a, b: b, distance: distance}], else: []
    end)
    |> Enum.sort_by(&{&1.distance, &1.a.name, &1.b.name})
  end

  defp pairs([]), do: []
  defp pairs([head | tail]), do: Enum.map(tail, &{head, &1}) ++ pairs(tail)

  # One read: every edge pointing at any of these documents, as the actor
  # (`ContentLink`'s read policy: editors see every edge of their site).
  defp unlinked(_org, _actor, []), do: []

  defp unlinked(org, actor, published) do
    ids = Enum.map(published, & &1.id)

    linked =
      CMS.list_content_links!(
        actor: actor,
        tenant: org,
        query: [filter: [target_id: [in: ids]], select: [:source_id, :target_id]]
      )
      |> Enum.reject(&(&1.source_id == &1.target_id))
      |> MapSet.new(& &1.target_id)

    Enum.reject(published, &MapSet.member?(linked, &1.id))
  end
end
