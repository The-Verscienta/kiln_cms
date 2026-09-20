defmodule KilnCMS.Firing.Sync do
  @moduledoc """
  The **sync API** behind `GET /api/sync`: a full snapshot of a site's public
  content, then only what changed since — upserts *and* deletions — so a
  static-site build, search index or edge cache can mirror Kiln without
  re-reading everything or missing what was taken down.

  `filter[updated_at][gt]` on JSON:API was the nearest substitute, and it cannot
  see a document leave: an unpublished, archived, deleted, locked or
  members-only document simply stops matching, which a poller cannot tell apart
  from "unchanged". The benchmark is Contentful's Sync API (`initial=true` →
  `nextSyncUrl` → deltas that include `DeletedEntry`).

  ## Who it serves

  **Anonymous visibility, always** — whoever calls. An upsert is a document an
  anonymous reader could fetch from `GET /api/content/:type/:slug` right now:
  published, `audience == :public`, not passphrase-locked (#496), not archived,
  and of a live content type. It is read through the resource's own policies
  with no actor (`authorize?: true`), the path the sitemap, feeds and search
  take, *and* filtered explicitly on the same rule, so neither a policy change
  nor a filter change alone can widen it. A document that stops qualifying —
  unpublished, archived, soft-deleted, purged, moved to a members audience,
  locked — is a **tombstone**: its id and type, and nothing else. Never a body,
  a slug or a reason.

  ## Where changes come from

  The PaperTrail version tables. Every editorial write to a document leaves a
  version row, so "which documents changed between two instants" is a range
  read over `version_inserted_at` (indexed per org — see
  `KilnCMS.CMS.VersionPolicies`). Each changed document is then classified by
  its **current** state, not by what the version says: a delta is "what to do
  to your copy now", and the current row is the authority on that.

  Hard purges are covered because version rows outlive the source row
  (`reference_source?(false)`), and a purge is itself a version.

  ## What a tombstone may name

  Only an id the sync API has already handed out, recorded in
  `KilnCMS.Firing.SyncExposure` when it was served. The version history alone
  would name every draft an editor touched and every document locked from its
  first save — and it cannot tell which were ever public, because the lock is
  deliberately absent from version rows. See the resource's moduledoc.

  ## Consistency

  Positions are opaque to this module's callers (the controller signs them). A
  delta covers the half-open window `(since, until]`, with `until` fixed on the
  delta's first page, so every page of one delta reads the same window, keyset
  by `{storage resource, id}`. The last page hands back a position whose
  `since` is that `until`.

  `until` trails the clock by a **commit lag** (default 10s, config
  `config :kiln_cms, KilnCMS.Firing.Sync, commit_lag_seconds: n`). A version's
  timestamp is taken when it is inserted, not when its transaction commits, so
  a window that ended at "now" could close over a write still in flight and
  never see it. The same lag is taken off the initial snapshot's start, so a
  write in flight while the snapshot was read is reported by the first delta.
  Both can report a document twice — every item is idempotent (an upsert
  replaces, a tombstone of something absent is a no-op), and a client applies
  them in order.

  ## What it does not see

  A change that writes no version: re-firing a document whose *fragment*
  changed, or whose content type's custom fields or SEO pattern did. The
  document's own artifact changes, but nothing about the document does.
  """

  require Ash.Query

  alias KilnCMS.CMS.Audiences
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Delivery
  alias KilnCMS.Firing.Engine
  alias KilnCMS.SystemActor

  @default_commit_lag_seconds 10

  # The fields an upsert needs, and nothing else — above all not `blocks`: the
  # body a caller gets is the fired artifact, never the editable tree.
  @record_fields [
    :id,
    :org_id,
    :slug,
    :locale,
    :state,
    :audience,
    :access_password_hash,
    :published_at,
    :updated_at
  ]

  @typedoc "Keyset resume point: a storage resource's module name and the last id."
  @type after_key :: {String.t(), Ash.UUID.t()} | nil

  @typedoc """
  Where a sync stands.

    * `{:initial, started_at, after}` — paging the snapshot that began at
      `started_at`.
    * `{:delta, since, until, after}` — paging the changes in `(since, until]`;
      `until` is `nil` until the delta's first page fixes it.
  """
  @type position ::
          {:initial, DateTime.t(), after_key()}
          | {:delta, DateTime.t(), DateTime.t() | nil, after_key()}

  @type item :: map()

  @type result ::
          {:ok, [item()], position(), boolean()}
          | {:error, :unknown_type}
          | :backfilling
          | :unavailable

  @doc "The position a new sync starts from."
  @spec start(DateTime.t()) :: position()
  def start(now \\ DateTime.utc_now()), do: {:initial, now, nil}

  @doc """
  One page of a sync.

  Returns `{:ok, items, next_position, has_more?}`. With `has_more?` true the
  caller should ask again straight away; with it false, `next_position` is the
  one to store and poll from later.

  `type` scopes the sync to one content type (compiled or dynamic) or, when
  `nil`, covers every type the org has. It must stay the same for every page
  and delta of one sync — the positions assume it.

  `:backfilling` means a document on this page has no fired artifact yet (a
  just-published document, while the async fire runs): a firing job is queued,
  and the same position will succeed on a retry. `:unavailable` is a database
  outage.

  Options: `:limit` (items per page), `:surface` (the artifact surface to
  embed, default `:json`), `:now` and `:commit_lag` (seconds) for tests.
  """
  @spec page(Ash.UUID.t(), String.t() | nil, position(), keyword()) :: result()
  def page(org_id, type, position, opts \\ []) do
    with {:ok, scopes} <- scopes(org_id, type) do
      ctx = %{
        org_id: org_id,
        limit: Keyword.get(opts, :limit, 100),
        surface: Keyword.get(opts, :surface, :json),
        live_definitions: live_definitions(org_id),
        now: Keyword.get(opts, :now) || DateTime.utc_now(),
        lag: Keyword.get(opts, :commit_lag) || commit_lag_seconds()
      }

      run(scopes, position, ctx)
    end
  rescue
    e ->
      if Delivery.db_unavailable?(e), do: :unavailable, else: reraise(e, __STACKTRACE__)
  end

  defp commit_lag_seconds do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:commit_lag_seconds, @default_commit_lag_seconds)
  end

  # ── Initial snapshot ─────────────────────────────────────────────────────

  defp run(scopes, {:initial, started_at, after_key}, ctx) do
    {records, next_after, more?} =
      collect(scopes, after_key, ctx.limit, fn scope, after_id, n ->
        visible(scope, ctx, after_id: after_id, limit: n)
      end)

    with {:ok, items} <- upserts(records, ctx) do
      record_exposures(records, ctx)

      next =
        if more?,
          do: {:initial, started_at, next_after},
          else: {:delta, lagged(started_at, ctx.lag), nil, nil}

      {:ok, items, next, more?}
    end
  end

  # ── Delta ────────────────────────────────────────────────────────────────

  defp run(scopes, {:delta, since, nil, after_key}, ctx) do
    until = lagged(ctx.now, ctx.lag)

    # Nothing can be settled yet: the window would end before it starts.
    if DateTime.compare(until, since) == :gt do
      run(scopes, {:delta, since, until, after_key}, ctx)
    else
      {:ok, [], {:delta, since, nil, nil}, false}
    end
  end

  defp run(scopes, {:delta, since, until, after_key}, ctx) do
    {ids_by_scope, next_after, more?} =
      collect(scopes, after_key, ctx.limit, fn scope, after_id, n ->
        scope
        |> changed_ids(ctx.org_id, since, until, after_id, n)
        |> Enum.map(&{scope, &1})
      end)

    with {:ok, items} <- classify(ids_by_scope, ctx) do
      next =
        if more?,
          do: {:delta, since, until, next_after},
          else: {:delta, until, nil, nil}

      {:ok, items, next, more?}
    end
  end

  defp lagged(at, lag), do: DateTime.add(at, -lag, :second)

  # Walk the scopes in keyset order from `after_key`, taking up to `limit`
  # rows. `fetch` returns rows for one scope, each either a record or a
  # `{scope, id}` pair — whatever it returns, its id is the keyset.
  #
  # "More" is claimed when a scope filled the page: a following page may then
  # come back empty, which costs a request, where the alternative (probing
  # every later scope for a row) costs a query per type on every page.
  defp collect(scopes, after_key, limit, fetch) do
    scopes
    |> resume_from(after_key)
    |> Enum.reduce_while({[], nil, false}, fn {scope, after_id}, {acc, last, _more?} ->
      remaining = limit - length(acc)
      rows = fetch.(scope, after_id, remaining)
      acc = acc ++ rows
      last = if rows == [], do: last, else: {scope.name, row_id(List.last(rows))}

      if length(rows) >= remaining,
        do: {:halt, {acc, last, true}},
        else: {:cont, {acc, last, false}}
    end)
  end

  defp row_id({_scope, id}), do: id
  defp row_id(%{id: id}), do: id

  # The scopes at or after `after_key`, each with the id to resume after.
  # Keyed by the resource's NAME, not its index in the list: a deploy that adds
  # a content type between two pages would shift every index after it.
  defp resume_from(scopes, nil), do: Enum.map(scopes, &{&1, nil})

  defp resume_from(scopes, {name, id}) do
    scopes
    |> Enum.drop_while(&(&1.name < name))
    |> Enum.map(fn
      %{name: ^name} = scope -> {scope, id}
      scope -> {scope, nil}
    end)
  end

  # ── Scopes: where each type's documents are stored ───────────────────────

  # One scope per storage table, in name order. A dynamic type shares the
  # entry tier (D17), so scoping to one narrows that table by definition.
  defp scopes(_org_id, nil) do
    compiled =
      ContentTypes.all()
      |> Enum.map(& &1.resource)
      |> Enum.uniq()
      |> Enum.map(&scope(&1, nil))

    {:ok, Enum.sort_by([scope(KilnCMS.CMS.Entry, nil) | compiled], & &1.name)}
  end

  defp scopes(org_id, type) do
    case ContentTypes.get(type, org_id) do
      %{source: :dynamic, definition: %{id: id}} -> {:ok, [scope(KilnCMS.CMS.Entry, id)]}
      %{resource: resource} when not is_nil(resource) -> {:ok, [scope(resource, nil)]}
      _ -> {:error, :unknown_type}
    end
  end

  defp scope(resource, definition_id),
    do: %{resource: resource, name: inspect(resource), definition_id: definition_id}

  # The org's dynamic types that delivery still serves — `ContentTypes.get/2`
  # is the gate `GET /api/content/:type/:slug` resolves through, and it does
  # not find an archived type. Their documents are not "visible" either.
  defp live_definitions(org_id) do
    org_id
    |> ContentTypes.dynamic_all()
    |> Map.new(&{&1.definition.id, to_string(&1.type)})
  end

  # ── Visibility ───────────────────────────────────────────────────────────

  # Documents an anonymous reader may read right now, keyset by id.
  #
  # Read through the resource's own policies with no actor — the rule that
  # keeps drafts, gated audiences and locked documents out of the sitemap,
  # feeds and search — AND filtered on the same rule explicitly, the way
  # `Audiences.public_to_anonymous?/1` states it. Either alone would do today;
  # both means a later edit to one cannot quietly widen what sync discloses.
  # Archived rows are excluded by AshArchival's base filter.
  defp visible(scope, ctx, opts) do
    query =
      scope.resource
      |> Ash.Query.for_read(:read, %{}, actor: nil, tenant: ctx.org_id, authorize?: true)
      |> Ash.Query.filter(
        state == :published and audience == :public and is_nil(access_password_hash)
      )
      |> Ash.Query.select(select_fields(scope))
      |> Ash.Query.sort(id: :asc)
      |> scope_to_definitions(scope, ctx)

    query =
      case opts do
        [ids: ids] ->
          Ash.Query.filter(query, id in ^ids)

        [after_id: after_id, limit: limit] ->
          query
          |> then(&if after_id, do: Ash.Query.filter(&1, id > ^after_id), else: &1)
          |> Ash.Query.limit(limit)
      end

    query
    |> Ash.read!()
    # Belt and braces for the belt and braces: nothing reaches a response
    # without passing the stated rule in Elixir too.
    |> Enum.filter(&Audiences.public_to_anonymous?/1)
  end

  defp select_fields(%{resource: KilnCMS.CMS.Entry}), do: [:type_definition_id | @record_fields]
  defp select_fields(_scope), do: @record_fields

  # A dynamic-type scope reads its own definition; the all-types entry scope
  # reads every LIVE definition — an archived type's documents are not served.
  defp scope_to_definitions(query, %{resource: KilnCMS.CMS.Entry, definition_id: nil}, ctx) do
    ids = Map.keys(ctx.live_definitions)
    Ash.Query.filter(query, type_definition_id in ^ids)
  end

  defp scope_to_definitions(query, %{definition_id: nil}, _ctx), do: query

  defp scope_to_definitions(query, %{definition_id: id}, _ctx),
    do: Ash.Query.filter(query, type_definition_id == ^id)

  # ── Changed documents ────────────────────────────────────────────────────

  # Every document with a version in `(since, until]`, keyset by id.
  #
  # Raw SQL for the shape Ash can't express: DISTINCT over version rows, read
  # through the `(org_id, version_inserted_at)` index. Version rows are never
  # returned — only the source ids — and each id is re-read through the
  # visibility rule above before anything about it reaches a response.
  #
  # A dynamic-type scope narrows by the source row's definition, or — for a
  # purged row, which has none — by the one the sync API recorded when it
  # disclosed the document. A purged document it never disclosed gets no
  # tombstone anyway.
  # sobelow_skip ["SQL.Query"]
  defp changed_ids(scope, org_id, since, until, after_id, limit) do
    version_table = AshPostgres.DataLayer.Info.table(Module.concat(scope.resource, Version))
    source_table = AshPostgres.DataLayer.Info.table(scope.resource)

    params = [
      dump_uuid(org_id),
      DateTime.to_naive(since),
      DateTime.to_naive(until),
      dump_uuid(after_id),
      limit
    ]

    {type_scope, params} =
      case scope.definition_id do
        nil ->
          {"", params}

        id ->
          {"""
           AND (
             EXISTS (SELECT 1 FROM #{source_table} s
                     WHERE s.id = v.version_source_id AND s.type_definition_id = $6)
             OR EXISTS (SELECT 1 FROM sync_exposures e
                        WHERE e.org_id = $1 AND e.document_id = v.version_source_id
                          AND e.type_definition_id = $6)
           )
           """, params ++ [dump_uuid(id)]}
      end

    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        SELECT DISTINCT v.version_source_id FROM #{version_table} v
        WHERE v.org_id = $1
          AND v.version_inserted_at > $2
          AND v.version_inserted_at <= $3
          AND ($4::uuid IS NULL OR v.version_source_id > $4)
          #{type_scope}
        ORDER BY v.version_source_id
        LIMIT $5
        """,
        params
      )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)

  # Current state decides: visible now → upsert; otherwise a tombstone, if and
  # only if the sync API disclosed it before.
  defp classify(ids_by_scope, ctx) do
    ids_by_scope
    |> Enum.chunk_by(fn {scope, _id} -> scope.name end)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      [{scope, _} | _] = chunk
      ids = Enum.map(chunk, fn {_scope, id} -> id end)

      case classify_scope(scope, ids, ctx) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        other -> {:halt, other}
      end
    end)
  end

  defp classify_scope(scope, ids, ctx) do
    records = visible(scope, ctx, ids: ids)
    by_id = Map.new(records, &{&1.id, &1})
    hidden = Enum.reject(ids, &Map.has_key?(by_id, &1))

    exposures =
      if hidden == [],
        do: %{},
        else:
          hidden
          |> Firing.sync_exposures_for!(actor: SystemActor.new(:sync), tenant: ctx.org_id)
          |> Map.new(&{&1.document_id, &1})

    with {:ok, upserts} <- upserts(records, ctx) do
      record_exposures(records, ctx)
      upserts_by_id = Map.new(upserts, &{&1.id, &1})

      # Back in id order, so a page reads the way the keyset walked it.
      items =
        Enum.flat_map(ids, fn id ->
          cond do
            item = upserts_by_id[id] -> [item]
            exposure = exposures[id] -> [tombstone(exposure)]
            true -> []
          end
        end)

      {:ok, items}
    end
  end

  # ── Items ────────────────────────────────────────────────────────────────

  defp upserts(records, ctx) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case artifact(record, ctx) do
        {:ok, body} -> {:cont, {:ok, [upsert(record, body, ctx) | acc]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      other -> other
    end
  end

  # The same cache-first artifact read delivery makes. A published document
  # with no artifact yet is queued for firing and the whole page retried — the
  # alternative, an upsert without a body, is a copy the client can't use and
  # won't be told about again until the document next changes.
  defp artifact(record, ctx) do
    type = Engine.document_type(record)

    case Delivery.read_artifact(record.org_id, type, record.id, ctx.surface) do
      {:ok, body} ->
        {:ok, body}

      :unavailable ->
        :unavailable

      :miss ->
        %{"org_id" => record.org_id, "type" => to_string(type), "id" => record.id}
        |> KilnCMS.Firing.FireWorker.new()
        |> Oban.insert()

        :backfilling
    end
  end

  defp upsert(record, body, ctx) do
    %{
      op: "upsert",
      type: type_name(record, ctx),
      id: record.id,
      slug: record.slug,
      locale: record.locale,
      published_at: record.published_at,
      updated_at: record.updated_at,
      artifact: body
    }
  end

  defp tombstone(exposure),
    do: %{op: "delete", type: exposure.type_name, id: exposure.document_id}

  defp type_name(%{type_definition_id: id}, ctx) when is_binary(id),
    do: Map.fetch!(ctx.live_definitions, id)

  defp type_name(record, _ctx), do: to_string(Engine.document_type(record))

  # Remember what was disclosed, so a later tombstone may name it. Inside the
  # page's own request: a page that answered without recording would let the
  # document vanish without a tombstone.
  defp record_exposures([], _ctx), do: :ok

  defp record_exposures(records, ctx) do
    records
    |> Enum.map(fn record ->
      %{
        document_type: Engine.document_type(record),
        document_id: record.id,
        type_name: type_name(record, ctx),
        type_definition_id: Map.get(record, :type_definition_id)
      }
    end)
    |> Firing.record_sync_exposure!(
      actor: SystemActor.new(:sync),
      tenant: ctx.org_id,
      bulk_options: [return_records?: false, return_errors?: true, stop_on_error?: true]
    )

    :ok
  end
end
