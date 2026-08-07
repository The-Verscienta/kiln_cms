defmodule KilnCMS.CMS.Fragments do
  @moduledoc """
  Inlines reusable content fragments into a block tree (#479).

  A `KilnCMS.Blocks.Fragment` block holds a reference; `expand/3` replaces it
  with the referenced document's own blocks, so every consumer downstream — the
  four fired surfaces and live HTML delivery — sees one flat tree and needs no
  knowledge of fragments.

  ## What expansion does not reach (yet)

  Write-time derivations run over the raw tree: the `search_text` column, the
  block embeddings, `word_count` and `reading_time_minutes` are all computed in
  `Changes.SetSearchText` on save, before any org-scoped read is available. So a
  page whose body is one fragment reports zero words and is unfindable by its
  fragment's text. The editor's own preview, SEO grade and a11y report have the
  same gap. Tracked in #910 — expanding there means making a write depend on a
  read, which is a decision worth taking deliberately rather than in passing.

  ## Where it runs, and where it must not

  Two callers: `KilnCMS.Firing.Engine.fire/2` (so artifacts carry the resolved
  body) and `KilnCMSWeb.ContentController` (which renders HTML live from the
  block tree rather than from an artifact).

  It must run **after** `Firing.References.rebuild/4`, which reads the raw tree.
  Expansion removes the fragment block, and with it the `:reference` field the
  edge is extracted from — rebuild on an expanded tree would drop the edge that
  makes publishing a fragment re-fire its referrers, quietly turning the feature
  into a one-shot copy.

  ## Failing closed

  A reference expands only when the target is **published**, in the same org,
  and inside the caller's audience. Anything else — missing, draft, archived,
  trashed, gated, a type that no longer exists — expands to nothing. A fragment
  is a pointer; a pointer to something the caller may not see has no safe
  rendering, and a placeholder would leak its existence.

  ## Cycles and depth

  Fragments may nest — a fragment whose body embeds another — so expansion
  recurses, which means a cycle would not terminate. Two bounds, both needed:

    * an **ancestry list**: a fragment already being expanded on this branch is
      skipped, so `A → B → A` inlines `A`'s body once and stops rather than
      looping. Ancestry rather than a global seen-set, because the same fragment
      legitimately appearing twice on a page must render twice. A list rather
      than a `MapSet` because it is bounded by `max_depth/0` — three entries, so
      membership is trivial, and it avoids the OTP-29 opaque-type warning two
      MapSet construction paths produce (#599);
    * a **depth cap** (`max_depth/0`), so a long non-cyclic chain can't fan a
      page out without limit.

  Both are enforced here rather than at write time: a cycle needs two documents
  to point at each other, and either write is individually fine.

  Depth alone bounds *depth*, not *breadth*: a host with B fragments, each of
  whose targets has B more, costs `B + B² + B³` reads. So two more bounds sit
  alongside them — targets are **memoized per expansion** (the same fragment
  twice is one query) and the whole expansion has a **fetch budget**
  (`max_fetches/0`), past which further fragments expand to nothing rather than
  recursing. An anonymous page render is not a place to discover how many
  documents an editor chained together.
  """

  require Ash.Query

  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.Fragment
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.CMS.TypedBlocks

  # How deep fragments may nest. Three is already an unusual amount of
  # indirection for shared content; past that a page is assembled from pieces
  # nobody can reason about.
  @max_depth 3

  # Hard ceiling on target reads per expansion, whatever the shape. Well past
  # any real page (a busy one has a handful of fragments), and low enough that a
  # pathological tree costs a bounded number of queries rather than B³.
  @max_fetches 64

  @doc "Deepest fragment nesting expansion follows."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "Most target reads one expansion will perform."
  @spec max_fetches() :: pos_integer()
  def max_fetches, do: @max_fetches

  @doc """
  Replace every `Fragment` block in `typed_blocks` with its target's blocks.

  Returns the tree unchanged when it holds no fragments — the overwhelmingly
  common case, and worth the check because this runs on every fire and every
  page render.

  ## Options

    * `:audiences` — the **gated** tiers the reader holds, on top of `:public`.
      A widening, exactly as `Content`'s `public_by_slug` treats the same
      option: an anonymous reader passes `[]`, and `[]` has to mean "public
      content only", not "nothing at all". Because the target read runs
      `authorize?: false`, its filter is the whole security boundary — so it
      gates the audience axis as well as publish state.
  """
  @spec expand([struct()], Ash.UUID.t(), keyword()) :: [struct()]
  def expand(typed_blocks, org_id, opts \\ []) do
    blocks = List.wrap(typed_blocks)

    if any_fragment?(blocks) do
      # `:ancestry` seeds the cycle guard with the document being expanded, so a
      # page embedding *itself* doesn't inline its own body a second time before
      # the guard catches it one level down.
      ancestry = opts |> Keyword.get(:ancestry, []) |> List.wrap()

      key = {__MODULE__, make_ref()}
      Process.put(key, %{targets: %{}, fetches: 0})

      try do
        do_expand(blocks, org_id, Keyword.put(opts, :memo, key), ancestry, 0)
      after
        Process.delete(key)
      end
    else
      blocks
    end
  end

  defp any_fragment?(blocks) do
    Enum.any?(blocks, fn
      %Fragment{} -> true
      %Columns{} = block -> block |> Columns.child_blocks_flat() |> any_fragment?()
      _other -> false
    end)
  end

  defp do_expand(blocks, org_id, opts, ancestry, depth) do
    Enum.flat_map(blocks, fn
      %Fragment{} = block ->
        inline(block, org_id, opts, ancestry, depth)

      # A fragment inside a column is inlined in place, so a shared CTA can live
      # in a layout cell. The children stay children — flattening them to the
      # top level would move the content out of its column.
      %Columns{} = block ->
        [expand_columns(block, org_id, opts, ancestry, depth)]

      block ->
        [block]
    end)
  end

  defp inline(%Fragment{ref: ref}, org_id, opts, ancestry, depth) do
    with false <- depth >= @max_depth,
         {type, id} when not is_nil(id) <- reference(ref),
         false <- {type, id} in ancestry,
         %{} = target <- fetch(type, id, org_id, opts) do
      target
      |> Map.get(:blocks)
      |> TypedBlocks.to_typed()
      |> do_expand(org_id, opts, [{type, id} | ancestry], depth + 1)
    else
      _ -> []
    end
  end

  defp expand_columns(%Columns{} = block, org_id, opts, ancestry, depth) do
    columns =
      for column <- block.columns || [] do
        children =
          column
          |> child_blocks()
          |> TypedBlocks.to_typed()
          |> do_expand(org_id, opts, ancestry, depth)
          # Back to the raw string-keyed shape a column stores: `Columns` reads
          # its children straight out of jsonb, so writing structs here would
          # leave the block holding something its own renderer can't parse.
          |> Enum.map(&TypedBlocks.input_map/1)

        Map.put(column, "blocks", children)
      end

    %{block | columns: columns}
  end

  # jsonb columns arrive string-keyed; a column built in code (a test, a seed)
  # may use atoms.
  defp child_blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks
  defp child_blocks(%{blocks: blocks}) when is_list(blocks), do: blocks
  defp child_blocks(_column), do: []

  # The stored reference shape, `%{"type" => …, "id" => …}`. Atom keys are
  # accepted because a block built in code (a test, a seed) writes them.
  #
  # Guarded, and total. `:reference` is currently a bare `:map` with no
  # constraints, and the editor's param normalization only rewrites a *binary*
  # `ref` — so a crafted nested-map payload stores verbatim, and an unguarded
  # `to_string/1` on it would raise on every anonymous render of the page from
  # then on. Anything that isn't a `{binary type, binary id}` pair is a miss.
  defp reference(%{"type" => type, "id" => id})
       when (is_binary(type) or is_atom(type)) and is_binary(id),
       do: {to_string(type), id}

  defp reference(%{type: type, id: id})
       when (is_binary(type) or is_atom(type)) and is_binary(id),
       do: {to_string(type), id}

  defp reference(_other), do: nil

  # Published, same org, inside the caller's audience — the filter is the whole
  # boundary here, since the read is unauthorized. A dynamic type is additionally
  # scoped by `type_definition_id`: entries share one table, so a bare id read
  # could otherwise cross types.
  # Memoized and budgeted. The same fragment twice on a page is one query, and
  # once `max_fetches/0` distinct targets have been read the expansion stops
  # fetching — a page assembled from more references than that is a runaway, not
  # a document, and an anonymous render must not pay for it.
  defp fetch(type, id, org_id, opts) do
    key = Keyword.fetch!(opts, :memo)
    state = Process.get(key)

    case Map.fetch(state.targets, {type, id}) do
      {:ok, cached} ->
        cached

      :error when state.fetches >= @max_fetches ->
        nil

      :error ->
        target = read_target(type, id, org_id, opts)

        Process.put(key, %{
          targets: Map.put(state.targets, {type, id}, target),
          fetches: state.fetches + 1
        })

        target
    end
  end

  defp read_target(type, id, org_id, opts) do
    # `:public` is always in the set — `:audiences` widens, it doesn't replace.
    # An anonymous reader arrives with `[]` (`reader_audiences/1`), and reading
    # that as "no audiences match" would make every fragment on the public site
    # render as nothing.
    audiences = [:public | List.wrap(Keyword.get(opts, :audiences, []))] |> Enum.uniq()

    with %{} = ct <- ContentTypes.get(type, org_id),
         resource <- Slugs.storage_resource(ct) do
      resource
      |> Ash.Query.filter(id == ^id and state == :published and audience in ^audiences)
      |> Ash.Query.select([:id, :blocks])
      |> scope_dynamic(ct)
      |> Ash.read_one!(authorize?: false, tenant: org_id)
    else
      _ -> nil
    end
  rescue
    # A malformed id (an importer's junk in a `:reference` field) is a miss,
    # not a 500 on a public page.
    _ -> nil
  end

  defp scope_dynamic(query, %{source: :dynamic, definition: definition}),
    do: Ash.Query.filter(query, type_definition_id == ^definition.id)

  defp scope_dynamic(query, _compiled), do: query
end
