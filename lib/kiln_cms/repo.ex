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
end
