defmodule KilnCMS.Repo do
  use AshPostgres.Repo,
    otp_app: :kiln_cms

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    # `vector` (pgvector) backs semantic-search embeddings — see
    # docs/semantic-search-plan.md. Requires the pgvector/pgvector Postgres image.
    # `pg_trgm` backs typo-tolerant autocomplete (trigram similarity on titles).
    ["ash-functions", "citext", "vector", "pg_trgm"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  # Two statements, because Postgrex sends one per `query/3` (extended protocol
  # — a semicolon-joined pair is a syntax error, not two settings).
  #
  # `hnsw.max_scan_tuples` is deliberately LEFT AT pgvector's default (20 000).
  # Lowering it caps the one path this change makes expensive — a filtered scan
  # that legitimately matches nothing walks the whole ceiling before concluding
  # it, which on 50 000 rows took an empty-tenant query from ~1 ms to ~80 ms,
  # and `/api/related` is public, anonymous and correctly empty for most
  # documents. But a ceiling is exactly the knob that trades recall back away,
  # and picking a number needs a real corpus to measure recall against; a
  # synthetic one of random high-dimensional vectors has no meaningful
  # "nearest" to lose. Guessing low would reintroduce the silent short list this
  # is fixing. Left at the default, measured, and documented as the knob to
  # reach for — see docs/semantic-search-plan.md.
  @vector_scan_settings ["SET hnsw.iterative_scan = strict_order"]

  # Every semantic-search query is a FILTERED approximate search, and pgvector
  # post-filters (#998).
  #
  # The HNSW index is on `embedding` alone and deliberately `all_tenants?: true`
  # — HNSW cannot be multicolumn, so `org_id` cannot be in it and the tenant
  # predicate is always applied to rows the index has already chosen. With
  # `hnsw.iterative_scan = off` (the default) the scan returns `ef_search` (40)
  # candidates once, and every row failing a `WHERE` is simply lost. Measured on
  # 20 000 rows in one org and 3 in another: a search by the small org returned
  # **zero** rows, silently. `not is_nil(embedding)`, `block_type` faceting and
  # `exclude_document_id` narrow it further, and MVCC-invisible tuples act as
  # the same kind of filter — which is why this also read as a test flake.
  #
  # `strict_order`, not `relaxed_order`: callers treat the ordering as meaning
  # something — relevance floors, near-duplicate thresholds, "nearest first" in
  # the docs — so returning approximately-ordered rows would trade a silent
  # recall bug for a silent ranking one. `hnsw.max_scan_tuples` (default 20 000)
  # is what bounds the extra work.
  #
  # Set per connection rather than per query because every HNSW read in this
  # application wants it, and a `SET LOCAL` at each call site is a list to
  # forget to add to. Safe before the extension exists (`ecto.create`, the first
  # migration): Postgres accepts a prefixed GUC it doesn't recognize as a
  # placeholder rather than erroring, so this cannot stop the repo connecting.
  #
  # `super/2` FIRST, and not optional: `AshPostgres.Repo` defines its own
  # `init/2` which injects `:installed_extensions`, `:default_prefix` and the
  # two migration paths, and it is `defoverridable` — so a bare `def init` here
  # replaces it wholesale and silently drops all four. `installed_extensions` is
  # what `AshPostgres.DataLayer.functions/1` gates the vector and trigram
  # function lists on, so losing it makes `vector_cosine_distance/2` and
  # `trigram_similarity/2` unresolvable in any expression that ever tries to use
  # them — on a repo whose own `installed_extensions/0` plainly lists both.
  @impl true
  def init(type, config) do
    {:ok, config} = super(type, config)

    {:ok,
     Keyword.put_new(
       config,
       :after_connect,
       {__MODULE__, :configure_vector_scan, []}
     )}
  end

  @doc false
  # `after_connect` target. Runs on every checked-out connection, including the
  # sandbox's, so tests exercise the same scan behaviour production does.
  def configure_vector_scan(conn) do
    Enum.each(@vector_scan_settings, &Postgrex.query!(conn, &1, []))
  end

  @doc """
  The `{host, database}` this repo is connected to.

  Used by the operator tasks that guard on the target before doing something
  they can't take back (`KilnCMS.Staging.scrub!/1`, `KilnCMS.Beta.provision!/1`).
  Handles both `url:`-style config (prod/staging via `DATABASE_URL`) and
  discrete `database:`/`hostname:` config (dev/test) — reading only the latter
  is how a `DATABASE_URL` deployment ends up guarded against the name `"?"`.
  """
  @spec target() :: {String.t(), String.t()}
  def target do
    config = config()

    case config[:url] do
      url when is_binary(url) ->
        uri = URI.parse(url)
        {uri.host || "?", String.trim_leading(uri.path || "", "/")}

      _ ->
        {to_string(config[:hostname] || "?"), to_string(config[:database] || "?")}
    end
  end
end
