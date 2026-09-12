import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

database_url =
  System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

maybe_ipv6 = if Env.flag("ECTO_IPV6", false), do: [:inet6], else: []

# Encrypt the Postgres connection by default. Set DATABASE_SSL=false only for a
# provider that genuinely cannot offer TLS (most managed Postgres — RDS,
# Supabase, Neon, Fly — require or strongly prefer it). When DATABASE_SSL_CACERTFILE
# points at the provider's CA bundle we verify the server certificate; otherwise
# we still encrypt but skip peer verification (verify_none) so deployment isn't
# blocked on cert plumbing.
#
# This is the #606 site the header refers to. Only an explicit off-spelling
# disables TLS now; anything unreadable keeps it on.
database_ssl? = Env.flag("DATABASE_SSL", true)

# A blank value counts as unset, like every flag above. Matching only `nil`
# sent `DATABASE_SSL_CACERTFILE=` — a routine .env/compose artifact — to the
# verify_peer branch with an empty path; :ssl then fails to read the bundle
# and every connection dies at boot, which is the opposite of the fallback
# this case exists to provide.
database_ssl_opts =
  case String.trim(System.get_env("DATABASE_SSL_CACERTFILE", "")) do
    "" ->
      [verify: :verify_none]

    cacertfile ->
      [verify: :verify_peer, cacertfile: cacertfile, depth: 3]
  end

config :kiln_cms,
       KilnCMS.Repo,
       [
         url: database_url,
         # Shared by web requests and Oban workers (~34 concurrent across the
         # split queues) — size up from 10 in production. See the pool-sizing
         # formula in docs/performance.md.
         pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
         # For machines with several cores, consider starting multiple pools of `pool_size`
         # pool_count: 4,
         socket_options: maybe_ipv6,
         ssl: database_ssl?
       ] ++ if(database_ssl?, do: [ssl_opts: database_ssl_opts], else: [])
