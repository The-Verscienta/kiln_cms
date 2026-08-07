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
