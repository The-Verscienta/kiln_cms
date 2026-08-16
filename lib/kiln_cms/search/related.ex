defmodule KilnCMS.Search.Related do
  @moduledoc """
  Embedding-driven content intelligence (#339, phase 2), built entirely on the
  block embeddings that already index every document (D16) — no new model, no
  external calls:

    * `related_documents/2` — "readers of this also want…", the public
      related-content surface (published documents only).
    * `near_duplicates/2` — documents whose content is suspiciously close to
      this one (any state — editors want to catch draft duplicates too).
    * `suggest_tags/2` — existing tags ranked by semantic similarity to the
      document, minus the ones already applied.
    * `content_gaps/2` — recorded search queries that found little or nothing
      (from the search-analytics log): what readers looked for and didn't get.

  Everything is org-scoped and a no-op (empty results) when semantic search is
  disabled, mirroring the rest of the search stack.

  ## Budget (#1076)

  `near_duplicates/2` and `suggest_tags/2` can both fall onto the
  model-inference path documented on `centroid/2` below — an unpublished
  document has no stored vector, so its centroid is computed on demand, one
  inference per block. `suggest_tags/2` additionally embeds every taxonomy tag
  not already cached. Both are routed through `KilnCMS.LLM.Budget` under the
  `"search_embedding"` feature (limits: `KilnCMS.Search.embedding_per_user_limit/0`
  / `embedding_per_org_limit/0` / `embedding_unattended_share/0`), the same
  shape `KilnCMS.Seo.draft/2` uses for LLM drafting (#943).

  A blocked call returns `{:error, {:rate_limited, retry_after_ms}}` or
  `{:error, :unattended_disabled}` instead of a list — callers that always
  expect `[neighbour()]` (or `[%{tag:, distance:}]`) need to handle that,
  the same as `KilnCMS.Seo.draft/2`'s callers handle its `{:error, _}`.
  `related_documents/2` degrades a budget block to `[]` rather than
  propagating it, keeping its long-standing "always a list" contract for the
  public `/api/related` surface — whose own anchor is always a published
  document, and `centroid/2` never computes on one (see there), so *that*
  caller never reaches the budget below.

  It is reached another way: `KilnCMS.Seo.Links.suggest/2` calls
  `related_documents/2` against the document **currently being edited** —
  routinely unpublished — for both the editor's internal-link panel and its
  `:suggest_links` automation twin. Both must forward `:user_id` /
  `:unattended?` through `suggest/2`'s own opts for the reserve guarantee
  below to hold; a call with no budget context attached still charges the
  org's raw bucket, just with no per-user throttle and no unattended reserve.

  Pass `:user_id` for the per-caller bucket (an automation rule uses a synthetic
  `"automation:<rule_id>"` identity — see `KilnCMS.Automation.RuleWorker`) and
  `unattended?: true` for a call nobody is waiting on, so it draws on the
  reserve share rather than the full org allowance. The org id is always
  `record.org_id` — never a separate option — since every caller already holds
  the record.
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.LLM.Budget
  alias KilnCMS.Search
  alias KilnCMS.Search.BlockIndexer
  alias KilnCMS.Search.VectorCache

  require Ash.Query

  @typedoc """
  A scored neighbouring document. `path` is the canonical *public page* path
  (alias-aware); note `KilnCMSWeb.RelatedController` deliberately emits an
  `/api/content/...` href instead, which is a different address for a
  different consumer.
  """
  @type neighbour :: %{
          type: String.t(),
          id: Ash.UUID.t(),
          slug: String.t(),
          title: String.t() | nil,
          path: String.t() | nil,
          distance: float()
        }

  @doc """
  Published documents most similar to `record` (nearest block embeddings,
  aggregated per document by minimum cosine distance). Options: `:limit`
  (default 5).
  """
  @spec related_documents(struct(), keyword()) :: [neighbour()]
  def related_documents(record, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    # `{:error, _}` degrades to `[]` here rather than propagating (unlike
    # `near_duplicates/2` and `suggest_tags/2`): this is the public
    # reader-facing surface and has always answered a plain list. It never
    # happens *through this surface* — the anchor is a published document, and
    # `centroid/2` never computes on one (see there) — but `KilnCMS.Seo.Links`
    # calls this same function against an unpublished draft, so the budget
    # below is reachable, just not from here (see the moduledoc).
    case neighbours(record, limit * 4, budget_context(record, opts)) do
      {:error, _reason} ->
        []

      list ->
        list
        |> resolve(record.org_id, published_only?: true, actor: nil)
        |> Enum.take(limit)
    end
  end

  @doc """
  Documents whose closest block sits within `:threshold` cosine distance of
  this document — near-duplicates, any workflow state. Defaults to
  `KilnCMS.Search.near_duplicate_threshold/0`, which carries the measurement
  (#1086): a reworded copy of a document sits at 0.04 and another document on
  the same subject at 0.19-0.21, so 0.1 separates "the same article rewritten"
  from "another article about sourdough".

  Pass `:actor` and the neighbours are resolved as that user, so a document
  they may not read never appears. Omit it (the automation path, which has no
  actor and is already trusted) and the reads run unauthorized. Unlike
  `related_documents/2` this deliberately spans every workflow state and
  audience, so on an actor-facing surface — the editor's panel — the actor is
  the only thing standing between a granular-RBAC-restricted editor (#332) and
  the title of a draft in a content type they were not given.

  Pass `:user_id` and `:unattended?` for the `KilnCMS.LLM.Budget` check the
  moduledoc describes (#1076) — a budget-blocked call returns `{:error,
  {:rate_limited, ms}}` or `{:error, :unattended_disabled}` instead of a list.
  """
  @spec near_duplicates(struct(), keyword()) ::
          [neighbour()] | {:error, {:rate_limited, non_neg_integer()} | :unattended_disabled}
  def near_duplicates(record, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, Search.near_duplicate_threshold())

    case neighbours(record, Keyword.get(opts, :limit, 20), budget_context(record, opts)) do
      {:error, reason} ->
        {:error, reason}

      list ->
        list
        |> Enum.filter(&(&1.distance <= threshold))
        |> resolve(record.org_id, published_only?: false, actor: opts[:actor])
    end
  end

  @doc """
  Existing tags ranked by similarity to the document's content, excluding the
  ones already applied. Returns `[%{tag, distance}]`, best first. Options:
  `:limit` (default 5), `:threshold` and `:actor`.

  With `:actor` the taxonomy is read as that user. Beyond the policy question,
  that keeps an editor-facing caller honest: a suggestion for a tag the
  editor's own tag picker doesn't list is a control with nothing to tick.

  ## A weak match is no match

  `:threshold` is a cosine-distance ceiling, like `near_duplicates/2`'s,
  defaulting to `KilnCMS.Search.suggest_tags_threshold/0`. Ranking alone is not
  enough here and the reason is structural: the candidate set is the site's
  entire tag list, so taking the top five of five means every tag is suggested
  for every document (#851). The panel then offers "carburetors" for a page
  about herbal tea, in the same type, at the same size, as a good match — and
  a suggester that always suggests something is one an editor learns to ignore.

  The ceiling is a **measured** number, not a derived one (#1086), and the two
  bands it sits between overlap — see `KilnCMS.Search.suggest_tags_threshold/0`
  for the measurement and `KilnCMS.TagSuggestionCorpus` for the corpus. So the
  default admits a few tags a human would not tick, deliberately: the failure it
  is tuned away from is the empty panel, which reads as a broken feature rather
  than as "nothing is close".

  Returning `[]` is a real answer, and the same one `near_duplicates/2` gives.
  Pass `threshold: 2.0` to rank without filtering — cosine distance is
  `1 - cos θ`, so it tops out at 2 for exactly-opposed vectors — which is what
  this did before #851 and is the way to measure a ceiling for a non-default
  embedder.

  A non-numeric `:threshold`, or a non-numeric `:suggest_tags_threshold` in
  config, **raises** rather than being ignored. It has to: Erlang orders
  `number < atom < bitstring`, so `0.9 <= nil` is `true` and a `nil` ceiling
  would pass every candidate — silently restoring the exact behaviour this
  option exists to end, with no crash and no warning to say so. `nil` is a
  tempting thing to write here because `:semantic_max_distance` sits three
  lines above it in `config/config.exs` and does mean "no ceiling"; this one
  does not have that spelling.

  Pass `:user_id` and `:unattended?` for the `KilnCMS.LLM.Budget` check the
  moduledoc describes (#1076): the centroid fallback and each un-cached tag
  embedding both draw on it, so a budget-blocked call returns `{:error,
  {:rate_limited, ms}}` or `{:error, :unattended_disabled}` instead of a list
  — including partway through the taxonomy, in which case nothing already
  scored is returned either. That is deliberate: a truncated ranking (the
  first N tags alphabetically, say) is a worse answer than none, because
  nothing about it tells the caller it stopped early.
  """
  @spec suggest_tags(struct(), keyword()) ::
          [%{tag: struct(), distance: float()}]
          | {:error, {:rate_limited, non_neg_integer()} | :unattended_disabled}
  def suggest_tags(record, opts \\ []) do
    actor = opts[:actor]
    threshold = Keyword.get(opts, :threshold, Search.suggest_tags_threshold())
    budget_ctx = budget_context(record, opts)

    unless is_number(threshold) do
      raise ArgumentError,
            "suggest_tags/2 needs a numeric :threshold, got #{inspect(threshold)}. " <>
              "Cosine distance runs 0..2; pass 2.0 to rank without filtering. " <>
              "(`nil` does not mean \"no ceiling\" here — it would compare as " <>
              "greater than every distance and quietly admit everything.)"
    end

    with true <- Search.semantic?(),
         centroid when is_list(centroid) <- centroid(record, budget_ctx) do
      applied =
        record
        |> Map.get(:tags)
        |> List.wrap()
        |> Enum.reject(&match?(%Ash.NotLoaded{}, &1))
        |> MapSet.new(& &1.id)

      # `select:` two fields (#1085): a 500-tag org loads 500 authorized rows
      # here to use `id` and `name`, and the suggestions carry the tag back to
      # the caller, so the rows are re-read for the winners only below.
      candidates =
        KilnCMS.CMS.list_tags!(
          actor: actor,
          authorize?: not is_nil(actor),
          tenant: record.org_id,
          query: [select: [:id, :name]]
        )
        |> Enum.reject(&MapSet.member?(applied, &1.id))

      # Make sure every candidate has a stored, current vector — the only
      # inference this function does, and only the first time a tag (or a
      # renamed tag) is seen; then the ceiling and the ranking are one query.
      with :ok <- ensure_tag_embeddings(candidates, record.org_id, budget_ctx) do
        nearest_tags(candidates, centroid, threshold, Keyword.get(opts, :limit, 5), record.org_id)
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> []
    end
  end

  @doc """
  Recorded search queries that found nothing — what readers looked for and
  the site didn't have (the Analytics `:zero_result` read). Options:
  `:limit` (default 20, most-searched first) and `:actor`.

  Unlike its siblings this reads no embeddings, so it is the one function here
  that still answers on a deployment with semantic search off — a keyword-only
  site records zero-result queries just the same.

  Pass `:actor` from a request context and the read is authorized as that user
  (the analytics read policy is editor-or-above); omit it and the read runs
  unauthorized, for the system callers — an automation job has no actor to
  offer and is already trusted.
  """
  @spec content_gaps(Ash.UUID.t() | struct(), keyword()) :: [map()]
  def content_gaps(org_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    KilnCMS.Analytics.zero_result_searches!(
      actor: actor,
      authorize?: not is_nil(actor),
      tenant: org_id,
      query: [limit: Keyword.get(opts, :limit, 20)]
    )
    |> Enum.map(&%{query: &1.query, searches: &1.count, results: &1.result_count})
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Nearest foreign block embeddings to this document's centroid, aggregated
  # per document by minimum distance. `{:error, reason}` propagates from a
  # budget-blocked centroid computation (#1076) instead of collapsing to `[]`,
  # so a caller that needs to tell "nothing similar" from "couldn't check" can.
  defp neighbours(record, fetch_limit, budget_ctx) do
    with true <- Search.semantic?(),
         centroid when is_list(centroid) <- centroid(record, budget_ctx) do
      KilnCMS.SearchIndex.nearest_block_embeddings!(
        %{vector: centroid, exclude_document_id: record.id, limit: fetch_limit * 3},
        authorize?: false,
        tenant: record.org_id,
        load: [semantic_distance: %{query_vector: centroid}]
      )
      |> Enum.group_by(&{&1.document_type, &1.document_id})
      |> Enum.map(fn {{type, id}, embeddings} ->
        {type, id, embeddings |> Enum.map(& &1.semantic_distance) |> Enum.min()}
      end)
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.take(fetch_limit)
      |> Enum.map(fn {type, id, distance} -> %{type: type, id: id, distance: distance} end)
    else
      {:error, reason} -> {:error, reason}
      _ -> []
    end
  end

  # The document's embedding centroid: the element-wise mean of its block
  # vectors (hierarchical embeddings already fold in ancestor context).
  #
  # Falls back to computing them in memory when the index has none (#852).
  # Vectors are written by firing and firing runs on publish, so a document that
  # has never been published had no centroid — which meant `near_duplicates/2`,
  # a **pre**-publication check, only became available once the thing it exists
  # to prevent had already happened.
  defp centroid(record, budget_ctx) do
    case stored_vectors(record) do
      [] -> unindexed_centroid(record, budget_ctx)
      vectors -> mean(vectors)
    end
  end

  # Computing costs one model inference PER BLOCK, so it is confined to the one
  # case that needs it: a document that has not been published.
  #
  # Not merely an optimisation. `/api/related` is public and anonymous, and its
  # anchor always resolves through `Delivery.published/4` — so a published
  # anchor is the only kind a stranger can name. Without this guard, an operator
  # who turns on semantic search without re-firing puts every published page in
  # the empty-`stored_vectors` state, and a crawler walking the site would then
  # drive N sequential inferences per request through one `Nx.Serving`. Gating
  # on state means the reader-facing surface keeps exactly the cheap behaviour
  # it had, whatever the index looks like — and it is why `related_documents/2`
  # never reaches the budget check below: its anchor is always published.
  defp unindexed_centroid(%{state: :published}, _budget_ctx), do: nil

  # Charges one unit per block the embed will actually reach the model for —
  # not one flat unit per call — so the budget tracks real inference volume.
  # `raw_cached?/1` uses the exact key `computed_centroid/1` (by way of
  # `BlockIndexer.block_vectors/1`) is about to look up, so a document whose
  # centroid was already computed and cached (by an earlier call in the same
  # panel load, say) costs nothing here, matching `ensure_tag_embeddings/3`
  # below.
  defp unindexed_centroid(record, budget_ctx) do
    uncached =
      record
      |> BlockIndexer.embedding_inputs()
      |> Enum.count(&(not VectorCache.raw_cached?(&1)))

    embedding_charge(budget_ctx, uncached, fn -> computed_centroid(record) end)
  end

  defp stored_vectors(record) do
    storage = KilnCMS.Firing.Engine.document_type(record)

    KilnCMS.SearchIndex.block_embeddings_for!(storage, record.id,
      authorize?: false,
      tenant: record.org_id
    )
    |> Enum.map(&to_list(&1.embedding))
    |> Enum.reject(&is_nil/1)
  end

  # The mean is arithmetic over vectors already memoized per block by
  # `KilnCMS.Search.VectorCache` (#964). Not free — a fully warm 200-block
  # document costs ~3ms of ETS copying and list arithmetic against ~7µs for a
  # single cached centroid — but nothing next to the inference it replaces, and
  # the centroid memo it replaces was the expensive kind of cheap.
  #
  # This used to memoize the whole centroid in `KilnCMS.Cache`, keyed on a hash
  # of the document's embedding inputs. That was wrong twice over: every save
  # minted a fresh key and left the previous one resident, and the entries it
  # evicted to make room were the `published:record:*` ones delivery serves from
  # during a database outage. Caching the *inputs* instead makes an edit cost one
  # inference rather than N, shares an entry between two documents containing the
  # same paragraph, and keeps an editing workload out of the delivery cache.
  #
  # Nothing is persisted — see `KilnCMS.Search.BlockIndexer.block_vectors/1` for
  # why a draft's vectors must not enter `block_embeddings`.
  defp computed_centroid(record) do
    case BlockIndexer.block_vectors(record) do
      [] -> nil
      vectors -> mean(vectors)
    end
  end

  # A forbidden read comes back as an error tuple, which drops the neighbour —
  # the same path a deleted one takes. The vector query above stays
  # unauthorized either way: `BlockEmbedding` is an internal index, and the
  # documents it points at are filtered here, one read at a time.
  defp resolve(neighbours, org_id, published_only?: published_only?, actor: actor) do
    read_opts = [actor: actor, authorize?: not is_nil(actor), tenant: org_id]

    Enum.flat_map(neighbours, fn %{type: storage, id: id, distance: distance} ->
      case ContentTypes.get_record(to_string(storage), id, read_opts) do
        {:ok, doc} -> neighbour_entry(doc, distance, published_only?)
        _ -> []
      end
    end)
  end

  # `published_only?` serves the reader-facing surfaces — `/api/related` and the
  # editor's internal-link suggestions — so it means "a page a reader can
  # actually open", i.e. published, public, and unlocked. Delivery draws the same line in
  # `Slugs.find_published_by_alias/3`; without the audience half, both surfaces
  # advertise member-gated pages to anonymous callers.
  defp neighbour_entry(doc, _distance, true) when doc.state != :published, do: []
  defp neighbour_entry(doc, _distance, true) when doc.audience != :public, do: []

  # ...and neither is one behind a passphrase (#496). Third clause rather than a
  # widened second, because the three exclusions are three different reasons and
  # a reader hitting this surface has satisfied none of them: the vector query
  # above runs unauthorized, so this is where the lock is actually enforced for
  # related content.
  defp neighbour_entry(doc, _distance, true)
       when not is_nil(:erlang.map_get(:access_password_hash, doc)),
       do: []

  defp neighbour_entry(doc, distance, _published_only?) do
    type = KilnCMS.Firing.Engine.public_type(doc)

    [
      %{
        type: type,
        id: doc.id,
        slug: doc.slug,
        title: doc.title,
        # The canonical public path, resolved here because we hold the whole
        # record: `public_path_for/2` honors a multi-segment `path_alias`
        # (#485), which callers rebuilding "/#{type}/#{slug}" themselves
        # silently get wrong. `nil` if the type no longer resolves.
        path: public_path(type, doc),
        distance: distance
      }
    ]
  end

  defp public_path(type, doc) do
    case ContentTypes.get(type, doc.org_id) do
      nil -> nil
      ct -> KilnCMS.CMS.Slugs.public_path_for(ct, doc)
    end
  end

  # #1085: the tags among `candidates` (already the actor's authorized,
  # unapplied list) whose persisted vector sits within `threshold` of the
  # centroid — nearest first, `limit` at most — as one pgvector query against
  # `KilnCMS.Search.TagEmbedding`. Ranked, filtered and truncated in SQL, so a
  # call that answers `[]` costs one query rather than N lookups and N cosine
  # computations that the ceiling then throws away.
  #
  # The winning tags are re-read by id (their full rows are what callers render
  # and `RuleWorker` applies); the candidate list only carried `id`/`name`.
  defp nearest_tags([], _centroid, _threshold, _limit, _org_id), do: []

  defp nearest_tags(candidates, centroid, threshold, limit, org_id) do
    by_id = Map.new(candidates, &{&1.id, &1})

    KilnCMS.SearchIndex.nearest_tag_embeddings!(
      %{
        vector: centroid,
        tag_ids: Map.keys(by_id),
        threshold: threshold * 1.0,
        limit: limit
      },
      authorize?: false,
      tenant: org_id
    )
    |> Enum.map(fn row ->
      %{tag: Map.fetch!(by_id, row.tag_id), distance: row.semantic_distance}
    end)
    |> rehydrate_tags(org_id)
  end

  # `select: [:id, :name]` above left every other tag field `%Ash.NotLoaded{}`;
  # a caller (the editor panel, `RuleWorker.apply_tags`) wants the row it would
  # get from `list_tags!/1`. One read for the winners only — at most `limit`.
  defp rehydrate_tags([], _org_id), do: []

  defp rehydrate_tags(scored, org_id) do
    ids = Enum.map(scored, & &1.tag.id)

    full =
      KilnCMS.CMS.Tag
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(authorize?: false, tenant: org_id)
      |> Map.new(&{&1.id, &1})

    Enum.map(scored, fn %{tag: %{id: id}} = entry ->
      %{entry | tag: Map.get(full, id, entry.tag)}
    end)
  end

  # Persist a vector for every candidate that has none, or whose stored row was
  # computed for a previous name (a rename). Missing/stale rows are the only
  # ones that reach the model. `VectorCache.cached?/1` gates the batch charge
  # below (#1076): a name already in the cache costs nothing to embed again,
  # and charging for it anyway would size the budget to the taxonomy's word
  # list instead of to actual inference volume — the exact failure
  # `VectorCache` exists to avoid. Checked once for the whole missing set — one
  # budget round trip charging the real uncached count, not one round trip per
  # tag — and a refused charge stops the fill before any of it runs, leaving
  # every candidate exactly as cached as it was; see `suggest_tags/2`'s doc for
  # why a partial ranking is worse than none. Rows already written by an
  # earlier call stay: they are correct, and this call is cheaper for them.
  defp ensure_tag_embeddings([], _org_id, _budget_ctx), do: :ok

  defp ensure_tag_embeddings(candidates, org_id, budget_ctx) do
    stored =
      KilnCMS.SearchIndex.tag_embeddings_for!(Enum.map(candidates, & &1.id),
        authorize?: false,
        tenant: org_id
      )
      |> Map.new(&{&1.tag_id, &1})

    missing =
      Enum.reject(candidates, fn tag ->
        case Map.get(stored, tag.id) do
          %{name: name, embedding: embedding} when is_list(embedding) -> name == tag.name
          _missing_or_empty -> false
        end
      end)

    uncached = Enum.count(missing, &(not VectorCache.cached?(&1.name)))

    embedding_charge(budget_ctx, uncached, fn ->
      Enum.each(missing, fn tag ->
        case tag_vector(tag.name) do
          vector when is_list(vector) ->
            store_tag_embedding(tag, vector, org_id)

          # The embedder answered nothing for this name; skip it (it will
          # simply not rank) rather than fail every other tag's suggestion.
          _ ->
            :ok
        end
      end)

      :ok
    end)
  end

  defp store_tag_embedding(tag, vector, org_id) do
    KilnCMS.SearchIndex.upsert_tag_embedding!(
      %{tag_id: tag.id, name: tag.name, embedding: vector, embedded_at: DateTime.utc_now()},
      authorize?: false,
      tenant: org_id
    )
  end

  # Tag-name vectors are pure functions of the (stable) name — memoized so a
  # 500-tag org doesn't re-run 500 model inferences per triggering event.
  #
  # In `VectorCache`, not `KilnCMS.Cache` (#964): this is embedding data, and it
  # was competing for the delivery cache's 10,000-entry budget with the
  # `published:record:*` entries `Firing.Delivery` serves from during a database
  # outage. An org with 500 tags running suggestions could evict pages that
  # would then 503.
  defp tag_vector(name), do: VectorCache.embed_document(name)

  # `record.org_id` — never a caller-supplied option — is the org bucket key,
  # since every caller here already holds the record. `:user_id` and
  # `:unattended?` come from `opts` because those genuinely vary per call: an
  # editor's own id for the panel, a synthetic `"automation:<rule_id>"` and
  # `unattended?: true` for `KilnCMS.Automation.RuleWorker` (#1076, mirroring
  # #943's `KilnCMS.Seo.draft/2` precedent).
  defp budget_context(record, opts) do
    %{
      org_id: record.org_id,
      user_id: opts[:user_id],
      unattended?: Keyword.get(opts, :unattended?, false)
    }
  end

  # `units` is how many uncached inputs the caller is about to embed — 0 skips
  # the budget round trip entirely (a fully-cached call is free and must stay
  # free, not merely cheap), matching `VectorCache.cached?/1`'s guarantee.
  defp embedding_charge(_budget_ctx, 0, fun), do: fun.()

  defp embedding_charge(%{org_id: org_id, user_id: user_id, unattended?: unattended?}, units, fun) do
    Budget.charge(
      "search_embedding",
      org_id,
      user_id,
      Search.embedding_budget_limits(unattended?, units),
      fun
    )
  end

  defp mean(vectors) do
    count = length(vectors)

    vectors
    |> Enum.zip_with(& &1)
    |> Enum.map(&(Enum.sum(&1) / count))
  end

  # Stored vectors round-trip as `Pgvector` structs or plain lists.
  defp to_list(nil), do: nil
  defp to_list(%Pgvector{} = v), do: Pgvector.to_list(v)
  defp to_list(list) when is_list(list), do: list
end
