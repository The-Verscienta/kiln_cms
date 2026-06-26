import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kiln_cms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kiln_cms, KilnCMSWeb.Endpoint, server: true
end

config :kiln_cms, KilnCMSWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :kiln_cms, KilnCMS.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kiln_cms, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kiln_cms, KilnCMSWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :kiln_cms,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # ## Object storage (S3-compatible)
  #
  # Opt into the S3 adapter by setting S3_BUCKET. Works with AWS S3, Cloudflare
  # R2, Backblaze B2, Wasabi, MinIO, etc. For any non-AWS provider, also set
  # S3_ENDPOINT_HOST (see KilnCMS.Storage.S3 docs for per-provider hosts).
  if bucket = System.get_env("S3_BUCKET") do
    config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

    s3_opts =
      [
        bucket: bucket,
        public_base_url:
          System.get_env("S3_PUBLIC_BASE_URL") ||
            raise("S3_BUCKET is set but S3_PUBLIC_BASE_URL is missing")
      ]

    # Most buckets are made public at the bucket level; only send a per-object
    # canned ACL (e.g. "public_read") if the provider/bucket needs one.
    s3_opts =
      case System.get_env("S3_ACL") do
        nil -> s3_opts
        acl -> Keyword.put(s3_opts, :acl, String.to_atom(acl))
      end

    config :kiln_cms, KilnCMS.Storage.S3, s3_opts

    config :ex_aws,
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      # R2 uses "auto"; B2/Wasabi/AWS use a real region.
      region: System.get_env("AWS_REGION") || "us-east-1"

    # Custom endpoint for any non-AWS S3-compatible store (R2/B2/Wasabi/MinIO).
    # Leave unset for AWS S3 (ExAws derives the host from the region).
    if endpoint_host = System.get_env("S3_ENDPOINT_HOST") do
      config :ex_aws, :s3,
        scheme: System.get_env("S3_ENDPOINT_SCHEME") || "https://",
        host: endpoint_host,
        port: String.to_integer(System.get_env("S3_ENDPOINT_PORT") || "443")
    end
  end

  # ## Meilisearch (optional, Phase 6)
  #
  # Opt into the typo-tolerant search backend by setting MEILI_URL. Leave it
  # unset to keep Postgres full-text search as the only backend. Run
  # `mix kiln.meili.reindex` once after enabling to backfill the index.
  if meili_url = System.get_env("MEILI_URL") do
    config :kiln_cms, KilnCMS.Search.Meilisearch,
      enabled: true,
      url: meili_url,
      master_key: System.get_env("MEILI_MASTER_KEY"),
      index: System.get_env("MEILI_INDEX") || "kiln_content"
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kiln_cms, KilnCMSWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kiln_cms, KilnCMSWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :kiln_cms, KilnCMS.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
