# Registers pgvector's Postgrex extension (alongside the standard Postgres ones)
# so `vector` columns encode/decode to/from `Pgvector` structs. Wired to the
# repo via `config :kiln_cms, KilnCMS.Repo, types: KilnCMS.PostgrexTypes`.
Postgrex.Types.define(
  KilnCMS.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
