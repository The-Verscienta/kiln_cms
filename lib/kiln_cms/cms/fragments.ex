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

  ## Fetches are not the cost that matters (#917)

  Those two bounds together are not enough, because they bound the wrong
  quantity. The memo returns a cached target **without spending budget**, and
  inlining re-runs the expansion over that target's whole tree at *every*
  occurrence — so the emitted tree still grows as `B^(depth+1)` while
  `max_fetches/0` counts only *distinct* targets.

  Four published pages, three of them holding 200 fragment blocks each pointing
  at the next, cost **3** of 64 fetches and emit **eight million** block
  structs — which then flow through `TypedBlocks.to_legacy/1`,
  `flatten_block_tree/1` and `enrich_block/3`, and get cached. `blocks` carries
  no length constraint and is writable over the headless API, so that is an
  anonymous `GET` away.

  So the real bound is `max_nodes/0`, charged against **blocks emitted by
  inlining** — the quantity that actually grows. It is checked before each
  inline and charged as each one returns, so exhaustion is detected part-way
  through a wide tree rather than after it has been built. Past it, further
  fragments expand to nothing, the same way an exhausted fetch budget behaves.

  Only inlined blocks are charged. A legitimately long page is not the problem
  this bounds, and charging its own blocks would truncate it.
  """

  require Ash.Query

  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.Fragment
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing.PointInTime

  # How deep fragments may nest. Three is already an unusual amount of
  # indirection for shared content; past that a page is assembled from pieces
  # nobody can reason about.
  @max_depth 3

  # Hard ceiling on target reads per expansion, whatever the shape. Well past
  # any real page (a busy one has a handful of fragments), and low enough that a
  # pathological tree costs a bounded number of queries rather than B³.
  @max_fetches 64

  # Hard ceiling on blocks *produced by inlining*, whatever the shape (#917).
  # A real page assembled from shared pieces contributes tens; this is three
  # orders of magnitude past that, and still small enough that the worst case is
  # a large list rather than an out-of-memory node.
  @max_nodes 5_000

  @doc "Deepest fragment nesting expansion follows."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "Most target reads one expansion will perform."
  @spec max_fetches() :: pos_integer()
  def max_fetches, do: @max_fetches

  @doc "Most blocks one expansion will produce by inlining."
  @spec max_nodes() :: pos_integer()
  def max_nodes, do: @max_nodes

  @doc """
  Replace every `Fragment` block in `typed_blocks` with its target's blocks.

  Returns the tree unchanged when it holds no fragments — the overwhelmingly
  common case, and worth the check because this runs on every fire and every
  page render.

  ## Options

    * `:as_of` — a `DateTime` making every target resolve to the body it
      carried at that instant, via `KilnCMS.Firing.PointInTime.snapshot_state/4`,
      instead of to its current published body (#917). Only point-in-time reads
      pass it. A target that was not published then expands to nothing, exactly
      as an unpublished one does today.
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
      Process.put(key, %{targets: %{}, fetches: 0, emitted: 0})

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
    Enum.flat_map(blocks, fn block ->
      # Checked per sibling, so a wide list inside an already-exhausted
      # expansion stops here rather than being built and then thrown away.
      if inlined?(depth) and exhausted?(opts),
        do: [],
        else: emit(block, org_id, opts, ancestry, depth)
    end)
  end

  # `depth > 0` means "inside an inlined target", which is exactly the content
  # the node budget bounds. A host's own blocks are never charged — a long page
  # is not what this bounds, and charging it would make the budget a page-length
  # limit.
  defp inlined?(depth), do: depth > 0

  defp emit(%Fragment{} = block, org_id, opts, ancestry, depth),
    do: inline(block, org_id, opts, ancestry, depth)

  # A fragment inside a column is inlined in place, so a shared CTA can live in a
  # layout cell. The children stay children — flattening them to the top level
  # would move the content out of its column.
  #
  # Charged as ONE block; its children are charged by the `do_expand/5` inside
  # `expand_columns/5`, at the same depth. Charging the *returned list's* length
  # instead is what let a `Columns`-wrapped target bypass the budget: a `Columns`
  # maps to exactly one element however many children it holds, so a target
  # whose whole payload sat inside one column cost 1 node while emitting the lot.
  defp emit(%Columns{} = block, org_id, opts, ancestry, depth) do
    expanded = expand_columns(block, org_id, opts, ancestry, depth)
    charge(opts, depth, 1)
    [expanded]
  end

  defp emit(block, _org_id, opts, _ancestry, depth) do
    charge(opts, depth, 1)
    [block]
  end

  defp inline(%Fragment{ref: ref}, org_id, opts, ancestry, depth) do
    # The node budget is checked FIRST, before the depth and reference guards:
    # once the expansion has emitted its ceiling there is nothing any further
    # fragment can legitimately add, and the check has to happen on the way in
    # so a wide sibling list stops part-way rather than after it has all been
    # built (#917).
    with false <- exhausted?(opts),
         false <- depth >= @max_depth,
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

  defp exhausted?(opts) do
    opts |> Keyword.fetch!(:memo) |> Process.get() |> Map.fetch!(:emitted) >= @max_nodes
  end

  # Charged where a block is actually produced, once each. Charging the whole
  # returned list as an inline unwound billed nested content once per level of
  # the chain, so `max_nodes/0` cut in at roughly a (depth+1)-th of the number
  # it names — the knob did not mean what its `@doc` said.
  defp charge(opts, depth, count) do
    if inlined?(depth) do
      key = Keyword.fetch!(opts, :memo)
      state = Process.get(key)
      Process.put(key, %{state | emitted: state.emitted + count})
    end

    :ok
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

        # `%{state | …}`, not a fresh map: the state also carries the node
        # budget, and rebuilding it here silently dropped that key.
        Process.put(key, %{
          state
          | targets: Map.put(state.targets, {type, id}, target),
            fetches: state.fetches + 1
        })

        target
    end
  end

  defp read_target(type, id, org_id, opts) do
    case Keyword.get(opts, :as_of) do
      %DateTime{} = as_of -> read_target_as_of(type, id, org_id, as_of, opts)
      _live -> read_target_live(type, id, org_id, opts)
    end
  end

  # The historical path. It re-applies the SAME visibility rules the live path
  # applies, against the values that were live at `as_of` — publish state (via
  # `last_transition/4` inside `snapshot_state/4`), audience, and the dynamic
  # type scope.
  #
  # The first cut of this skipped the audience check, on the reasoning that
  # point-in-time reads are admin-gated. They are not: `ArtifactController.show/2`
  # dispatches to the point-in-time path on a bare `?as_of=` query parameter, on
  # a route in the unauthenticated `:api` pipeline, and serves the result with
  # `cache-control: public, max-age=300`. So an anonymous caller could append
  # `?as_of=` to any public URL and read — and have a CDN cache — the body of a
  # `:member` fragment embedded in it. A historical read must be no more
  # permissive than a live one; the point of the feature is *when*, not *who*.
  defp read_target_as_of(type, id, org_id, as_of, opts) do
    with %{} = ct <- ContentTypes.get(type, org_id),
         resource <- Slugs.storage_resource(ct),
         {:ok, state} <- PointInTime.snapshot_state(org_id, resource, id, as_of),
         true <- visible_then?(state, ct, opts) do
      %{id: id, blocks: Map.get(state, "blocks") || []}
    else
      _ -> nil
    end
  end

  # `audience` is on the version row's `changes` as a string. A replayed state
  # with no `audience` fails closed: it means the fold could not establish what
  # the target's audience was, and "unknown" must not read as "public" on a path
  # whose output is publicly cacheable.
  defp visible_then?(state, ct, opts) do
    allowed = opts |> allowed_audiences() |> MapSet.new(&to_string/1)

    MapSet.member?(allowed, Map.get(state, "audience")) and dynamic_scope_ok?(state, ct)
  end

  # Entries share one table, so a bare id read could otherwise cross dynamic
  # types — the live path applies this as `scope_dynamic/2`, and the historical
  # one has to as well, or a reference to a "recipe" resolves to an "event".
  defp dynamic_scope_ok?(state, %{source: :dynamic, definition: definition}),
    do: Map.get(state, "type_definition_id") == definition.id

  defp dynamic_scope_ok?(_state, _compiled), do: true

  # `:public` is always in the set — `:audiences` widens, it doesn't replace. An
  # anonymous reader arrives with `[]` (`reader_audiences/1`), and reading that
  # as "no audiences match" would make every fragment on the public site render
  # as nothing. Shared by both paths so they cannot drift apart.
  defp allowed_audiences(opts),
    do: [:public | List.wrap(Keyword.get(opts, :audiences, []))] |> Enum.uniq()

  defp read_target_live(type, id, org_id, opts) do
    audiences = allowed_audiences(opts)

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
