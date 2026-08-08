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

  @default_index "kiln_content"

  # ── Config ────────────────────────────────────────────────────────────────

  @doc "Whether the Meilisearch backend is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: cfg(:enabled, false)

  @doc "Base URL of the Meilisearch instance."
  @spec url() :: String.t()
  def url, do: cfg(:url, "http://localhost:7700")

  @doc "Master/API key sent as a bearer token, or `nil` for an unsecured instance."
  @spec master_key() :: String.t() | nil
  def master_key, do: cfg(:master_key, nil)

  @doc "Name of the Meilisearch index holding KilnCMS content."
  @spec index_name() :: String.t()
  def index_name, do: cfg(:index, @default_index)

  @doc "The configured HTTP client adapter module."
  @spec client() :: module()
  def client, do: cfg(:client, KilnCMS.Search.Meilisearch.ReqClient)

  # ── Index management ──────────────────────────────────────────────────────

  @doc """
  Declare the index's searchable / filterable / sortable attributes. Idempotent —
  safe to call on every reindex. Meilisearch creates the index on first write, so
  this just applies settings. No-op when the backend is disabled.
  """
  @spec configure() :: {:ok, term()} | {:error, term()} | :disabled
  def configure do
    if enabled?() do
      request(:patch, "/indexes/#{index_name()}/settings", %{
        searchableAttributes: ["title", "excerpt", "body"],
        # `org_id` is filterable so every query can force the tenant facet (#336).
        filterableAttributes: ["org_id", "type", "locale"],
        sortableAttributes: ["published_at"]
      })
    else
      :disabled
    end
  end

  @doc """
  Upsert a single content record (Page/Post) into the index. Documents are keyed
  by `"<type>_<id>"`, so re-publishing replaces the prior document. No-op when
  disabled.

  **Refuses anything not public to an anonymous visitor** (`:not_public`) rather
  than trusting the caller. `MeilisearchWorker` already decides this — it turns a
  gated document into a DELETE, which is the stronger answer — but this is public
  API taking any struct, and `to_document/1` puts the whole denormalized body in
  `body`. A console helper or a future bulk path calling it on a members-only
  page would otherwise index that page silently, with no error and nothing to
  catch it (#1006).
  """
  @spec index_document(struct()) :: {:ok, term()} | {:error, term()} | :disabled | :not_public
  def index_document(record) do
    cond do
      not enabled?() -> :disabled
      not KilnCMS.CMS.Audiences.public_to_anonymous?(record) -> :not_public
      true -> upsert_documents([to_document(record)])
    end
  end

  @doc "Upsert pre-built documents (see `to_document/1`). No-op when disabled."
  @spec upsert_documents([map()]) :: {:ok, term()} | {:error, term()} | :disabled
  def upsert_documents([]), do: :ok

  def upsert_documents(documents) when is_list(documents) do
    if enabled?() do
      request(:put, "/indexes/#{index_name()}/documents?primaryKey=id", documents)
    else
      :disabled
    end
  end

  @doc """
  Remove a document from the index by content `type` and `id`. No-op when
  disabled.
  """
  @spec delete_document(:page | :post | :entry | String.t(), String.t()) ::
          {:ok, term()} | {:error, term()} | :disabled
  def delete_document(type, id) do
    if enabled?() do
      request(:delete, "/indexes/#{index_name()}/documents/#{document_id(type, id)}", nil)
    else
      :disabled
    end
  end

  # ── Search ────────────────────────────────────────────────────────────────

  @doc """
  Query the index. Returns the raw Meilisearch hits (maps with the indexed
  fields plus `_formatted` highlights). Options:

    * `:org_id` — **required** (epic #336): the tenant to scope results to. Every
      query forces `org_id = "<id>"`, so search never spans orgs.
    * `:limit` — max hits (default 20)
    * `:type` — restrict to a type facet: `:page`, `:post`, or a dynamic
      type's name (#1012)
    * `:locale` — restrict to a locale

  Returns `{:error, :disabled}` when the backend is off.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    if enabled?() do
      body =
        %{q: query, limit: Keyword.get(opts, :limit, 20)}
        |> put_filter(opts)

      case request(:post, "/indexes/#{index_name()}/search", body) do
        {:ok, %{"hits" => hits}} -> {:ok, hits}
        {:ok, _other} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :disabled}
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

  defp request(method, path, body) do
    client().request(method, path, body, %{url: url(), master_key: master_key()})
  end

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
