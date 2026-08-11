defmodule KilnCMS.Firing.Engine do
  @moduledoc """
  Fires a document into immutable per-surface artifacts (Kiln v2 — decision D9).

  `fire/2` walks the document's block tree (converting legacy storage to typed
  blocks via `KilnCMS.CMS.TypedBlocks`), renders each v1 surface through the typed
  serializers, upserts a `PublishedArtifact` per surface, warms the cache, and
  broadcasts `{:fired, type, id}`. `mode: :preview` compiles to memory only (no DB,
  no cache) for live editor previews.

  `read/4` is the delivery path: cache → artifact table, **never** the live tree.
  Every read/write is scoped to the document's `org_id` tenant (epic #336).
  """
  require Logger

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.Fragments
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Cache

  # `:llm` (#357) is the Markdown surface answer engines extract from.
  @surfaces KilnCMS.Firing.Surfaces.all()
  # Bumped when a surface's serialized shape changes (decision A2). v2 added
  # `custom_fields` to `:json` and `contentLocation` to `:json_ld` (#428/#429).
  @format_version 2

  @enqueue_log_key {__MODULE__, :last_refire_enqueue_failure_ms}
  @future_log_key {__MODULE__, :last_future_artifact_ms}
  @log_every_ms :timer.minutes(1)

  @doc "Fire a document. Returns `{:ok, %{surface => body}}`."
  @spec fire(struct(), keyword()) :: {:ok, %{atom() => map()}}
  def fire(document, opts \\ []) do
    mode = Keyword.get(opts, :mode, :persist)
    type = document_type(document)
    # The tenant rides on the document itself (epic #336): every content struct
    # carries `org_id`, so firing is scoped to the document's own org with no
    # extra plumbing at the call sites.
    org_id = document.org_id
    start = System.monotonic_time()

    typed = document |> Map.get(:blocks) |> TypedBlocks.to_typed()

    # Reusable fragments are inlined here, once, before any surface renders
    # (#479 — decision A3 taken literally). Every surface, plus `body_text/1`
    # below and everything derived from it, then sees one flat tree and needs no
    # knowledge of fragments.
    #
    # `typed` — the RAW tree — is what `References.rebuild/4` gets at the bottom
    # of this function, deliberately: expansion removes the fragment block and
    # with it the `:reference` the edge is extracted from, so rebuilding on the
    # expanded tree would drop the edge that makes publishing a fragment re-fire
    # its referrers.
    #
    # Expanded with the **host document's own** audience, and nothing wider.
    # An artifact is keyed to the host, and every artifact consumer —
    # `ArtifactController`, the feeds, static export, the newsletter — resolves
    # that host through a `:public`-only filter and then serves the body
    # verbatim. Firing with every audience would therefore put a `:member`
    # fragment's text into a `:public` page's artifact and hand it to anonymous
    # callers, which is exactly the leak this feature must not have. Keeping the
    # host's own audience makes the artifact no more permissive than the
    # document carrying it — the rule delivery already enforces.
    expanded =
      Fragments.expand(typed, org_id,
        audiences: host_audiences(document),
        # `fragments: <DateTime>` makes expansion resolve each target as it was
        # at that instant rather than as it is now (#917). Only point-in-time
        # reads pass it; every other fire leaves it nil and reads live.
        as_of: Keyword.get(opts, :fragments),
        # Seeded with the document itself, so a page embedding *itself* doesn't
        # inline its own body once before the cycle guard catches it a level
        # down.
        ancestry: [{public_type(document), document.id}]
      )

    # Custom fields are resolved once and shared by every surface: the read is
    # one query, and computed fields (#429) are recomputed exactly once per
    # fire rather than once per surface.
    #
    # `custom_fields: :as_stored` opts out of recomputation and of projecting
    # onto the current definitions — for point-in-time reads, where deriving
    # from today's formulas and today's field registry would report values that
    # were never live at the requested instant.
    custom =
      KilnCMS.Firing.CustomFields.resolve(document, body_text(expanded),
        recompute?: Keyword.get(opts, :custom_fields, :recompute) == :recompute
      )

    artifacts =
      Map.new(@surfaces, fn surface ->
        {surface, compose(document, expanded, custom, surface)}
      end)

    if mode == :persist do
      persist(document, type, org_id, artifacts)
      reindex_search_text(document, org_id, expanded)
      # Keep the dependency graph current (decision D13). Invalidation of
      # referrers is enqueued by the caller (publish hook / re-fire worker), not
      # here, to keep fire/2 free of recursion.
      KilnCMS.Firing.References.rebuild(org_id, type, document, typed)
    end

    # Firing-duration telemetry (#206): wall-clock of the per-surface render
    # (+ persist on :persist), tagged by mode so persist vs preview are separable.
    :telemetry.execute(
      [:kiln_cms, :firing, :fire],
      %{duration: System.monotonic_time() - start, count: 1},
      %{type: type, mode: mode}
    )

    {:ok, artifacts}
  end

  # The gated tiers a document's own artifact may carry: its own, when gated.
  # A `:public` document carries public fragments only.
  #
  # Public (not `defp`) so `KilnCMSWeb.ContentEditorLive` can expand the same
  # way for its own preview/SEO panel (#910) — a fragment inside a `:member`
  # document must not be expanded there with a wider audience than delivery
  # will ever grant it, or the editor's own preview would show text a reader
  # of the finished page could never see.
  @doc false
  @spec host_audiences(struct()) :: [atom()]
  def host_audiences(document) do
    case Map.get(document, :audience) do
      nil -> []
      :public -> []
      audience -> [audience]
    end
  end

  # A fragment block's own `search_text` is always `""` — it renders nothing
  # itself — so `search_text` (denormalized at save time by
  # `Changes.SetSearchText`, from the RAW tree) never carries a fragment's
  # words, and stays that way until something recomputes it (#910). Every
  # fire already builds `expanded` for the rendered surfaces; recomputing here
  # too keeps FTS/Meilisearch/document-embedding text in sync with what a
  # reader actually sees, on both an initial fire and a re-fire wave
  # (`RefireWorker` calls `fire/2` too, so a referrer's `search_text` catches
  # up when the fragment it embeds changes, not just when the referrer itself
  # is next edited).
  #
  # Its own narrow action, for the reason `:set_oembed_metadata` documents:
  # no webhook, no re-fired version, no lock bump for a derived column, and no
  # `:blocks` in `accept` — this never touches the document's own stored
  # content, only the denormalized text summarizing it. Skipped when nothing
  # changed, which is the common case (most documents carry no fragment, so
  # `expanded` equals `typed` and the recomputed text already matches).
  defp reindex_search_text(document, org_id, expanded) do
    search_text =
      KilnCMS.CMS.Changes.SetSearchText.compute(document, body_text(expanded))

    if search_text != Map.get(document, :search_text) do
      document
      |> Ash.Changeset.for_update(:reindex_search_text, %{search_text: search_text},
        authorize?: false,
        tenant: org_id
      )
      |> Ash.update()
      |> case do
        {:ok, _updated} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "fire: search_text reindex failed for #{document.id}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  @doc "Read a fired artifact body for a surface: cache, then the artifact table."
  @spec read(Ash.UUID.t(), atom(), Ash.UUID.t(), atom()) :: {:ok, map()} | :error
  def read(org_id, type, id, surface) do
    case Cache.get(org_id, type, id, surface) do
      {:ok, body} ->
        {:ok, body}

      :miss ->
        case Firing.get_artifact(type, id, surface, authorize?: false, tenant: org_id) do
          {:ok, %{body: body} = artifact} ->
            # Cache BEFORE enqueuing: a job cannot start before its insert
            # returns, so this ordering guarantees the re-fire's fresh body is
            # written after ours rather than being clobbered by it.
            Cache.put(org_id, type, id, surface, body)
            migrate_if_stale(org_id, type, id, artifact)
            {:ok, body}

          _ ->
            :error
        end
    end
  end

  @doc """
  The serialized shape version this build writes (decision A2).

  Bumped whenever a surface's shape changes. v2 added `custom_fields` to `:json`
  and `contentLocation` to `:json_ld` (#428/#429).
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Whether a stored artifact predates the shape this build writes.

  `nil` and a missing key read as current: a row that cannot say what it is
  should not be re-fired on every read.
  """
  @spec stale?(term()) :: boolean()
  def stale?(%{format_version: version}) when is_integer(version), do: version < @format_version
  def stale?(_artifact), do: false

  @doc """
  Enqueue a re-fire when `artifact` predates the current shape (#615).

  ## Why lazy, rather than a sweep

  Bumping `@format_version` used to be **decorative**: nothing read the field and
  nothing re-fired, so after a shape change every document published before the
  deploy kept serving the old shape indefinitely while everything published after
  served the new one — and a consumer could not tell which, because the field that
  would say so was never consulted. Meanwhile the headless guide documented the
  new keys as present on every surface.

  Reading it here makes the field load-bearing: a bump to an **existing** surface
  is handled by the same branch, with no deploy step for anyone to forget.

  ## What this does not cover

  A bump that **adds a surface** is not detectable here: there is no row for the
  new surface, so the read is a plain not-found and `stale?/1` is never reached.
  `mix kiln.refire_all` is still required for that case, and remains the faster
  option for any large corpus — this path only reaches documents that are read.

  Convergence is **eventual, not next-request**. The stale body is served this
  time and cached (`Cache`'s TTL is an hour), so reads in between are cache hits
  on the old shape until the job lands and overwrites both the row and the cache.

  Enqueueing is best-effort: a failure here must not fail the read, which is the
  delivery path and is expected to survive a database outage (#341).
  """
  @spec migrate_if_stale(Ash.UUID.t(), atom(), Ash.UUID.t(), term()) :: :ok
  def migrate_if_stale(org_id, type, id, artifact) do
    cond do
      stale?(artifact) -> enqueue_refire(org_id, type, id)
      from_future?(artifact) -> warn_future_artifact(type, id, artifact)
      true -> :ok
    end
  end

  # A row stamped NEWER than this build wrote it means the release was rolled
  # back after firing. Re-firing would silently DOWNGRADE the served body, so it
  # is left alone — but it is served verbatim by a build whose own serializers
  # would not produce it, which is worth one line rather than nothing at all.
  defp from_future?(%{format_version: version}) when is_integer(version),
    do: version > @format_version

  defp from_future?(_artifact), do: false

  defp warn_future_artifact(type, id, %{format_version: version}) do
    throttled(@future_log_key, fn ->
      Logger.warning(
        "Artifact for #{type} #{inspect(id)} was fired at format_version #{version}, " <>
          "newer than this build's #{@format_version} — most likely a rolled-back " <>
          "release. It is served as stored rather than downgraded; run " <>
          "`mix kiln.refire_all` if you intend this build's shape to win. " <>
          "Logged at most once a minute."
      )
    end)
  end

  defp enqueue_refire(org_id, type, id) do
    # `FireWorker`'s `unique` window collapses concurrent enqueues into one JOB —
    # but not into one INSERT: each caller still pays a round-trip and an advisory
    # lock for the uniqueness check. So the cost of a popular stale document under
    # a cold cache is one write per cache miss until the re-fire lands, not one
    # write total. Bounded, and only until the document stops being stale.
    %{org_id: org_id, type: to_string(type), id: id}
    |> KilnCMS.Firing.FireWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      # A rejected changeset is not an exception, so it would otherwise vanish.
      {:error, reason} -> log_enqueue_failure(type, id, inspect(reason))
    end
  rescue
    # A read-only replica or a downed pool raises rather than returning an error
    # tuple. The read has already succeeded by this point, so swallow it: failing
    # the request over a background-migration enqueue would trade a served page
    # for an error page.
    error -> log_enqueue_failure(type, id, Exception.message(error))
  end

  # Throttled for the same reason the enqueue is best-effort: on a read-only
  # replica EVERY delivery cache miss fails here, and an unthrottled line would
  # turn a degraded database into log amplification on the one path documented to
  # stay quiet through an outage.
  defp log_enqueue_failure(type, id, reason) do
    throttled(@enqueue_log_key, fn ->
      Logger.warning(
        "Could not enqueue a format-version re-fire for #{type} #{inspect(id)}: #{reason}. " <>
          "Artifacts stay on their stored shape until this succeeds or " <>
          "`mix kiln.refire_all` is run. Logged at most once a minute."
      )
    end)
  end

  @doc false
  # Exposed so tests can start from a known throttle state — otherwise the first
  # warning in a run silences every later one for a minute, making any test that
  # asserts on these lines order-dependent.
  def reset_log_throttles do
    Enum.each([@enqueue_log_key, @future_log_key], &:persistent_term.erase/1)
    :ok
  end

  defp throttled(key, fun) do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(key, nil)

    if is_nil(last) or now - last >= @log_every_ms do
      :persistent_term.put(key, now)
      fun.()
    end

    :ok
  end

  @doc "Delete every fired artifact for a document and evict the cache (unpublish)."
  @spec purge(Ash.UUID.t(), atom(), Ash.UUID.t()) :: :ok
  def purge(org_id, type, id) do
    {:ok, artifacts} = Firing.artifacts_for(type, id, authorize?: false, tenant: org_id)
    Enum.each(artifacts, &Ash.destroy!(&1, authorize?: false, tenant: org_id))
    Cache.evict(org_id, type, id)
    :ok
  end

  @doc "The content type atom for a document struct (`:page` / `:post` / `:entry`)."
  @spec document_type(struct()) :: atom()
  def document_type(%{__struct__: module}) do
    # A content resource declares its canonical type atom via the Content macro;
    # trust it rather than reverse-deriving from the module name. Downcasing the
    # module's last segment loses the underscores in a multi-word type
    # (`TcmIngredient` -> "tcmingredient", not `:tcm_ingredient`), so
    # `String.to_existing_atom/1` would raise for any multi-word content type.
    if function_exported?(module, :__kiln_content_type__, 0) do
      module.__kiln_content_type__()
    else
      module |> Module.split() |> List.last() |> String.downcase() |> String.to_existing_atom()
    end
  end

  @doc """
  The consumer-facing type string for a document: a compiled type's atom name,
  or the owning dynamic type's name for a generic entry (D17) — the `:entry`
  storage key is an implementation detail headless consumers never see.
  """
  @spec public_type(struct()) :: String.t()
  # `is_binary(id)` and not `not is_nil(id)`: on a partially-selected read the
  # attribute is `%Ash.NotLoaded{}`, which is not nil — so the old guard passed,
  # queried with a NotLoaded struct as the id, failed, and quietly answered
  # "entry". This is public API whose `@doc` invites a bulk caller, and the
  # symptom was a wrong type on every dynamic document plus one failing query
  # each, with nothing raised (#1012).
  def public_type(%{type_definition_id: id, org_id: org_id}) when is_binary(id) do
    # The definition read is tenant-strict (#419): scope to the document's own
    # org, else the read raises and every dynamic doc silently degrades to the
    # "entry" storage key in webhooks/provenance/search.
    case KilnCMS.CMS.get_type_definition(id, authorize?: false, tenant: org_id) do
      {:ok, definition} -> definition.name
      # Archived/removed definition — fall back to the storage key.
      _ -> "entry"
    end
  end

  def public_type(document), do: to_string(document_type(document))

  defp persist(document, type, org_id, artifacts) do
    fired_at = DateTime.utc_now()

    Enum.each(@surfaces, fn surface ->
      {:ok, _} =
        Firing.upsert_artifact(
          %{
            document_type: type,
            document_id: document.id,
            surface: surface,
            format_version: @format_version,
            body: artifacts[surface],
            source_version_id: Map.get(document, :published_version_id),
            fired_at: fired_at
          },
          # `org_id` is set from the tenant (writable? false), so pass it as the
          # tenant rather than in the attrs map.
          authorize?: false,
          tenant: org_id
        )

      Cache.put(org_id, type, document.id, surface, artifacts[surface])
    end)

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, "firing", {:fired, type, document.id})
  end

  # ── per-surface composition (whole-doc artifact of per-block fragments, A1) ──

  defp compose(_document, typed, _custom, :web) do
    html = typed |> Enum.map(&Blocks.render(&1, :web)) |> IO.iodata_to_binary()
    %{"html" => html}
  end

  defp compose(document, typed, custom, :json) do
    %{
      # `id` + `type` address the document for the visual-editing bridge (#355):
      # `(type, id, <field>)` locates a document scalar (title/slug), while each
      # block map carries its own `_id` for `(block_id, <field>)`. Additive and
      # non-sensitive (an opaque uuid) — safe on the public artifact.
      "id" => Map.get(document, :id),
      "type" => public_type(document),
      "title" => Map.get(document, :title),
      "slug" => Map.get(document, :slug),
      # Locale rides with the document identity (`[slug, locale]`) so the bridge
      # can deep-link the correct variant (#1104). Absent on pre-#1104 artifacts.
      "locale" => Map.get(document, :locale),
      # The admin-defined custom fields (D4). Already public on the delivery
      # APIs; carrying them here means the fired artifact is a complete view of
      # the document, and is what makes computed fields (#429) part of what
      # publishing produces.
      "custom_fields" => custom.values,
      "blocks" => Enum.map(typed, &Blocks.render(&1, :json))
    }
  end

  # Clean chunked Markdown for LLM/answer-engine extraction (#357, GEO).
  defp compose(document, typed, _custom, :llm) do
    %{"markdown" => KilnCMS.Firing.LlmMarkdown.compose(document, typed)}
  end

  defp compose(document, typed, custom, :json_ld) do
    # The main node's @type is declared per content type (#357, GEO): the
    # Content macro's `schema_org_type:` option or the dynamic type's
    # definition — so a health-domain type fires e.g. a MedicalWebPage.
    main =
      document
      |> KilnCMS.Firing.SchemaOrg.main_node(body_text(typed, "\n\n"))
      # A geolocation custom field (#428) is the document's contentLocation:
      # a Place carrying GeoCoordinates.
      |> put_content_location(KilnCMS.Firing.CustomFields.content_location(custom))
      # An Event-typed document's dates come from its `datetime_range` field
      # (#480). Only for the Event family: `startDate` on an Article is not a
      # property schema.org defines.
      |> put_event_schedule(document)

    # Structured data falls out of the typed blocks (decision D9): each block that
    # has a schema.org representation contributes a node to the document @graph. A
    # block may yield nil (no node), one node, or — for a container block like
    # `columns` — a list of its children's nodes, so flatten before assembling.
    block_nodes = typed |> Enum.flat_map(&json_ld_nodes/1)

    %{"@context" => "https://schema.org", "@graph" => [main | block_nodes]}
  end

  defp put_content_location(node, nil), do: node
  defp put_content_location(node, location), do: Map.put(node, "contentLocation", location)

  # `startDate`/`endDate` from the schedule field, and the recurrence as an
  # `eventSchedule` — schema.org's own `Schedule`, which carries an RRULE
  # verbatim, so a search engine sees the rule rather than a window of expanded
  # instances that goes stale the moment it is fired.
  defp put_event_schedule(%{"@type" => type} = node, document) do
    if KilnCMS.Firing.SchemaOrg.event_type?(type),
      do: Map.merge(node, KilnCMS.Events.schema_org_schedule(document)),
      else: node
  end

  defp put_event_schedule(node, _document), do: node

  # The document's plain text, from the already-typed blocks. `:json_ld` wants
  # paragraph separation; the computed-field context (`word_count`,
  # `reading_time`) only counts words, so the separator is immaterial there.
  defp body_text(typed, separator \\ " ") do
    typed
    |> Enum.map(&Blocks.search_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(separator)
  end

  # Normalize a block's `:json_ld` render (nil | node map | list of nodes) to a
  # flat list of nodes for the @graph.
  defp json_ld_nodes(block) do
    case Blocks.render(block, :json_ld) do
      nil -> []
      nodes when is_list(nodes) -> Enum.reject(nodes, &is_nil/1)
      node -> [node]
    end
  end
end
