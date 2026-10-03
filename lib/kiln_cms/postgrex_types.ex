# Registers pgvector's Postgrex extensions (alongside the standard Postgres
# ones) so `vector` columns encode/decode to/from `Pgvector` structs. Wired to
# the repo via `config :kiln_cms, KilnCMS.Repo, types: KilnCMS.PostgrexTypes`.
#
# All three pgvector types, not only the `vector` Kiln stores: the extension
# installs `halfvec` and `sparsevec` too, and a type Postgrex cannot handle
# makes any query naming it fail. The test suite loads every installed type
# before it starts (`KilnCMS.Test.TypeCache`, #1796), so it needs each one to
# be loadable.
Postgrex.Types.define(
  KilnCMS.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
