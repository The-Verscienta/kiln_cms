defmodule KilnCMS.Search.Meilisearch do
  @moduledoc """
  Optional typo-tolerant search backend (KilnCMS Project Plan — Phase 6).

  Meilisearch is a **feature-flagged** alternative to the built-in Postgres
  full-text search: faceted, typo-tolerant keyword search for published content.
  It is **off by default** (`enabled: false`) so the lean install never talks to
  it and pays nothing. Enable it (and point it at a running instance — see the
  `search` Docker Compose profile) via:

      config :kiln_cms, KilnCMS.Search.Meilisearch,
        enabled: true,
        url: "http://localhost:7700",
        master_key: System.get_env("MEILI_MASTER_KEY"),
        index: "kiln_content"

  ## Which instance

  One per site (#1558): a site admin can point their site at their own
  instance from `/editor/site-search`, and the operator's `MEILI_*` instance
  serves every site that has not. Everything here that touches a site's
  documents or queries resolves the instance through
  `KilnCMS.Search.Meilisearch.SiteInstance` — the one resolver, so indexing and
  search always agree — or takes a target a caller already resolved.
  `enabled?/0`, `url/0`, `master_key/0` and `index_name/0` describe the
  **operator's** instance only.

  ## Indexing

  Published Page/Post documents are pushed into Meilisearch off the write path:
  publishing (or scheduled publishing) enqueues an upsert and unpublishing
  enqueues a delete, both via `KilnCMS.Search.MeilisearchWorker` — wired from
  `KilnCMS.CMS.Changes.FireArtifacts` / `DeleteArtifacts`. `mix kiln.meili.reindex`
  does a full (re)build.

  **Only content that is public to an anonymous visitor.** Published, `audience:
  :public`, and not passphrase-locked — `KilnCMS.CMS.Audiences.public_to_anonymous?/1`
  is the rule, and `index_document/1` enforces it rather than trusting callers.
  The index has no audience, grant or password facet (see `to_document/1` and
  `configure/0`) and its queries carry no actor, so anything in it is readable by
  everyone who can reach it: the only correct entry for content that is not
  public is none (#1006, #496). See `docs/meilisearch.md`.

  HTTP is delegated to a swappable `KilnCMS.Search.Meilisearch.Client` (default
  Req); tests inject a stub.
  """

  alias KilnCMS.Firing.Engine
  alias KilnCMS.Search.Meilisearch.SiteInstance

  @default_index "kiln_content"

  # ── Config ────────────────────────────────────────────────────────────────

  @doc "Whether the operator's Meilisearch instance (`MEILI_URL`) is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: cfg(:enabled, false)

  @doc """
  Whether indexing is on for the site `org_id` — its own instance or the
  operator's. The gate the publish path asks before enqueueing a
  `KilnCMS.Search.MeilisearchWorker` job; see `SiteInstance.active?/1`.
  """
  @spec enabled_for?(Ash.UUID.t() | nil) :: boolean()
  def enabled_for?(org_id), do: SiteInstance.active?(org_id)

  @doc "Base URL of the operator's Meilisearch instance."
  @spec url() :: String.t()
  def url, do: cfg(:url, "http://localhost:7700")

  @doc "The operator's master/API key, sent as a bearer token, or `nil` for an unsecured instance."
  @spec master_key() :: String.t() | nil
  def master_key, do: cfg(:master_key, nil)

  @doc "Name of the operator's Meilisearch index holding KilnCMS content."
  @spec index_name() :: String.t()
  def index_name, do: cfg(:index, @default_index)

  @doc "The configured HTTP client adapter module."
  @spec client() :: module()
  def client, do: cfg(:client, KilnCMS.Search.Meilisearch.ReqClient)

  # ── Index management ──────────────────────────────────────────────────────

  @doc """
  Declare the index's searchable / filterable / sortable attributes. Idempotent —
  safe to call on every reindex. Meilisearch creates the index on first write, so
  this just applies settings.

  `configure/0` configures the operator's instance (`:disabled` when there is
  none); `configure/1` the given target, such as a site's own.
  """
  @spec configure() :: {:ok, term()} | {:error, term()} | :disabled
  def configure do
    case SiteInstance.resolve(nil) do
      {:ok, target} -> configure(target)
      :disabled -> :disabled
    end
  end

  @spec configure(SiteInstance.target()) :: {:ok, term()} | {:error, term()}
  def configure(%{index: index} = target) do
    request(target, :patch, "/indexes/#{index}/settings", %{
      searchableAttributes: ["title", "excerpt", "body"],
      # `org_id` is filterable so every query can force the tenant facet (#336).
      filterableAttributes: ["org_id", "type", "locale"],
      sortableAttributes: ["published_at"]
    })
  end

  @doc """
  Apply the index settings (`configure/0`) and enqueue a
  `KilnCMS.Search.MeilisearchWorker` upsert for every published Page, Post and
  Entry across every org, so the index is fully (re)built in the background.
  Returns `{:ok, count}` with the number of documents enqueued.

  This is the release-callable form of `mix kiln.meili.reindex` (which wraps
  it) — a production OTP release has no Mix, so run it there as

      bin/kiln_cms rpc 'KilnCMS.Search.Meilisearch.reindex_all()'

  Also the **removal** path: the worker turns a document it will not index into
  a `DELETE`, so a run enqueued over every published document evicts the ones
  that should no longer be there (audience-gated or passphrase-locked content
  indexed under an older rule, #1006/#496). No-op (`:disabled`) when the
  operator's backend is off.

  Every org's documents are enqueued, including a site's that uses its own
  instance: each job resolves its site's instance when it runs, so those land
  there, never here. That instance's settings are applied by
  `reindex_org/1`, which every save of the site's settings enqueues.
  """
  @spec reindex_all() :: {:ok, non_neg_integer()} | {:error, term()} | :disabled
  def reindex_all do
    case configure() do
      :disabled -> :disabled
      {:error, _} = error -> error
      {:ok, _} -> {:ok, enqueue_documents(KilnCMS.Accounts.list_org_ids())}
    end
  end

  @doc """
  `reindex_all/0` for one site, into whichever instance it resolves to now
  (`SiteInstance.resolve/1`): applies that instance's index settings, then
  enqueues an upsert for each of the site's published documents. Run by
  `KilnCMS.Search.MeilisearchWorker` for a `"reindex"` job, which every write
  to the site's `KilnCMS.CMS.SiteMeilisearch` row enqueues.

  `{:error, reason}` when the site's own instance is set but cannot be used,
  or refuses the settings — the job retries, and nothing is sent to the
  operator's instance instead. `:disabled` when the site uses no instance.
  """
  @spec reindex_org(Ash.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()} | :disabled
  def reindex_org(org_id) when is_binary(org_id) do
    with {:ok, target} <- SiteInstance.resolve(org_id),
         {:ok, _} <- configure(target) do
      {:ok, enqueue_documents([org_id])}
    end
  end

  defp enqueue_documents(org_ids) do
    Enum.reduce(reindex_sources(), 0, &enqueue_reindex_source(&1, &2, org_ids))
  end

  # Page, Post and every dynamic-type entry (D17). Entries are one source, not
  # one per type: they all live in the `:entry` tier and fire under the `entry`
  # storage key, which is the key `MeilisearchWorker.load/3` dispatches on
  # (#1012). A function, not a module attribute: captures evaluated in the
  # module body are a compile-time dependency on `KilnCMS.CMS` (and its whole
  # closure); inside a function body they are runtime calls.
  defp reindex_sources do
    [
      {KilnCMS.CMS.Page, &KilnCMS.CMS.list_pages!/1},
      {KilnCMS.CMS.Post, &KilnCMS.CMS.list_posts!/1},
      {KilnCMS.CMS.Entry, &KilnCMS.CMS.list_entries!/1}
    ]
  end

  defp enqueue_reindex_source({_resource, lister}, acc, org_ids) do
    # Strict tenancy (#419): list published docs per org (reads need a tenant).
    #
    # Bypass kept (#1402), for the reason `MeilisearchWorker.load/3` gives: a
    # system-actor clause on the `Content` read policy would be a standing
    # corpus-wide grant. What bounds this instead is the query — one org at a
    # time, `state: :published`, and a select of `[:id, :state, :org_id]`, so
    # only ids leave here and they leave as Oban job args.
    published =
      Enum.flat_map(org_ids, fn org_id ->
        lister.(
          authorize?: false,
          tenant: org_id,
          query: [filter: [state: :published], select: [:id, :state, :org_id]]
        )
      end)

    published
    |> Enum.map(fn record ->
      type = Engine.document_type(record)

      KilnCMS.Search.MeilisearchWorker.new(%{
        "org_id" => record.org_id,
        "op" => "upsert",
        "type" => to_string(type),
        "id" => record.id
      })
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Oban.insert_all/1)

    acc + length(published)
  end

  @doc """
  Upsert a single content record (Page/Post) into its site's index. Documents
  are keyed by `"<type>_<id>"`, so re-publishing replaces the prior document.
  No-op when the site uses no instance.

  **Refuses anything not public to an anonymous visitor** (`:not_public`) rather
  than trusting the caller. `MeilisearchWorker` already decides this — it turns a
  gated document into a DELETE, which is the stronger answer — but this is public
  API taking any struct, and `to_document/1` puts the whole denormalized body in
  `body`. A console helper or a future bulk path calling it on a members-only
  page would otherwise index that page silently, with no error and nothing to
  catch it (#1006).

  `index_document/1` resolves the record's site's instance (an unusable one is
  `{:error, reason}`, never the operator's); `index_document/2` takes a target
  the caller already resolved, so one job asks once.
  """
  @spec index_document(struct()) :: {:ok, term()} | {:error, term()} | :disabled | :not_public
  def index_document(record) do
    case SiteInstance.resolve(record.org_id) do
      {:ok, target} -> index_document(target, record)
      :disabled -> :disabled
      {:error, _reason} = error -> error
    end
  end

  @spec index_document(SiteInstance.target(), struct()) ::
          {:ok, term()} | {:error, term()} | :not_public
  def index_document(target, record) do
    if KilnCMS.CMS.Audiences.public_to_anonymous?(record),
      do: upsert_documents(target, [to_document(record)]),
      else: :not_public
  end

  @doc """
  Upsert pre-built documents (see `to_document/1`) into the operator's
  instance (`upsert_documents/1`, `:disabled` when there is none) or into
  `target`.
  """
  @spec upsert_documents([map()]) :: :ok | {:ok, term()} | {:error, term()} | :disabled
  def upsert_documents([]), do: :ok

  def upsert_documents(documents) when is_list(documents) do
    case SiteInstance.resolve(nil) do
      {:ok, target} -> upsert_documents(target, documents)
      :disabled -> :disabled
    end
  end

  @spec upsert_documents(SiteInstance.target(), [map()]) ::
          :ok | {:ok, term()} | {:error, term()}
  def upsert_documents(_target, []), do: :ok

  def upsert_documents(%{index: index} = target, documents) when is_list(documents),
    do: request(target, :put, "/indexes/#{index}/documents?primaryKey=id", documents)

  @doc """
  Remove a document from the index by content `type` and `id` — from the
  operator's instance (`delete_document/2`, `:disabled` when there is none),
  or from `target`.
  """
  @spec delete_document(:page | :post | :entry | String.t(), String.t()) ::
          {:ok, term()} | {:error, term()} | :disabled
  def delete_document(type, id) do
    case SiteInstance.resolve(nil) do
      {:ok, target} -> delete_document(target, type, id)
      :disabled -> :disabled
    end
  end

  @spec delete_document(SiteInstance.target(), :page | :post | :entry | String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def delete_document(%{index: index} = target, type, id),
    do: request(target, :delete, "/indexes/#{index}/documents/#{document_id(type, id)}", nil)

  # ── Search ────────────────────────────────────────────────────────────────

  @doc """
  Query the site's index — its own instance or the operator's, whichever
  `SiteInstance.resolve/1` names for `:org_id`. Returns the raw Meilisearch
  hits (maps with the indexed fields plus `_formatted` highlights). Options:

    * `:org_id` — **required** (epic #336): the tenant to scope results to. Every
      query forces `org_id = "<id>"`, so search never spans orgs.
    * `:limit` — max hits (default 20)
    * `:type` — restrict to a type facet: `:page`, `:post`, or a dynamic
      type's name (#1012)
    * `:locale` — restrict to a locale

  Returns `{:error, :disabled}` when the site uses no instance, and
  `{:error, {:site_instance, reason}}` — **without making any request** — when
  the site set its own instance and it cannot be used. A caller falls back to
  the built-in Postgres search (`KilnCMS.Search`) on any error. It never gets
  the operator's index instead: that index holds other sites' content, and a
  site that chose its own instance did not choose to be answered from it (see
  `SiteInstance`).
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    # Built first: it raises on a missing `:org_id` before anything is resolved.
    body =
      %{q: query, limit: Keyword.get(opts, :limit, 20)}
      |> put_filter(opts)

    case SiteInstance.resolve(opts[:org_id]) do
      {:ok, target} -> run_search(target, body)
      :disabled -> {:error, :disabled}
      {:error, reason} -> {:error, {:site_instance, reason}}
    end
  end

  defp run_search(%{index: index} = target, body) do
    case request(target, :post, "/indexes/#{index}/search", body) do
      {:ok, %{"hits" => hits}} -> {:ok, hits}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Document shape ────────────────────────────────────────────────────────

  @doc """
  Build the flat Meilisearch document for a content record. `published_at` is an
  integer unix timestamp so it is sortable/filterable.
  """
  @spec to_document(struct()) :: map()
  def to_document(record) do
    %{
      # Keyed on the STORAGE type (`page`/`post`/`entry`), because the delete
      # path has only `{type, id}` from the job args and cannot resolve
      # anything from a record that may already be gone — so upsert and delete
      # have to agree on a key that both can compute (#1012).
      id: document_id(Engine.document_type(record), record.id),
      # The owning org (#336) — indexed as a filterable facet so search can scope
      # per site. The `id` stays global (a UUID; no cross-org collision).
      org_id: record.org_id,
      # ...but the FACET is the consumer-facing type: `recipe`, not the `entry`
      # storage key every dynamic type shares. A front end filtering
      # `type = "recipe"` is the whole reason this field is filterable, and
      # "entry" for all of them answers nothing.
      type: Engine.public_type(record),
      record_id: record.id,
      title: record.title,
      slug: record.slug,
      locale: record.locale,
      excerpt: Map.get(record, :excerpt),
      body: record.search_text,
      published_at: unix(record.published_at)
    }
  end

  @doc """
  The Meilisearch primary key for a content record (alphanumeric/`-`/`_` only).

  Takes the **storage** type — `page`, `post`, or `entry` for every dynamic type
  — not the consumer-facing facet, so the delete path can compute the same key
  from job args alone. See `to_document/1`.
  """
  @spec document_id(:page | :post | :entry | String.t(), String.t()) :: String.t()
  def document_id(type, id), do: "#{type}_#{id}"

  # ── Internals ─────────────────────────────────────────────────────────────

  defp put_filter(body, opts) do
    # `org_id` is a MANDATORY tenant facet (#336): every query forces it so search
    # can never span orgs. A UUID, so quoted (like `locale`, unlike bare `type`).
    org_id = opts[:org_id] || raise ArgumentError, "Meilisearch.search/2 requires :org_id"

    filters =
      [
        ~s(org_id = "#{org_id}"),
        # Unquoted, unlike `org_id`/`locale`, because a Meilisearch filter takes
        # a bare token here. Safe because a dynamic type's `name` is validated
        # `~r/\A[a-z][a-z0-9_]*\z/` and is create-only
        # (`KilnCMS.CMS.TypeDefinition`), so it cannot carry a quote, a space or
        # an operator — and `Validations.AvailableTypeName` stops it colliding
        # with `page`/`post`. That safety lives in another resource, so relaxing
        # that charset (hyphens, say) breaks this line silently (#1012).
        opts[:type] && "type = #{opts[:type]}",
        opts[:locale] && ~s(locale = "#{opts[:locale]}")
      ]
      |> Enum.reject(&is_nil/1)

    Map.put(body, :filter, Enum.join(filters, " AND "))
  end

  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp unix(_), do: nil

  # Only the target's own URL and key go into the request — for a site's
  # target, nothing of the operator's. `safe:` sends a site's request through
  # `KilnCMS.SafeFetch` (see `ReqClient`).
  defp request(target, method, path, body) do
    client().request(method, path, body, %{
      url: target.url,
      master_key: target.master_key,
      safe: target.safe
    })
  end

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
