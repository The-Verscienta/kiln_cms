defmodule KilnCMSWeb.RateLimit do
  @moduledoc """
  ETS-backed rate limiter for API and auth endpoints (Hammer fixed window).
  """
  use Hammer, backend: :ets

  @default_limits %{
    gql: {60, :timer.minutes(1)},
    api: {120, :timer.minutes(1)},
    auth: {20, :timer.minutes(1)},
    # Public HTML delivery — generous, just a flood/abuse ceiling per IP.
    delivery: {300, :timer.minutes(1)},
    # Signed preview links — tight, to slow token enumeration / draft scraping.
    preview: {30, :timer.minutes(1)},
    # Public form submissions — tight per IP; a human fills a handful of
    # forms a minute, a spammer fills hundreds.
    form: {20, :timer.minutes(1)},
    # Always-on Swagger UI explorer (#225) — generous for human browsing, caps
    # crawler/abuse traffic against the docs UI.
    docs: {60, :timer.minutes(1)},
    # Infra/SEO endpoints (`/up`, `/sitemap.xml`, `/robots.txt`). Generous so
    # legitimate load-balancer probes and crawlers are never throttled, while
    # still bounding a flood that would otherwise run an unthrottled DB query
    # (`/up`) or table scan (sitemap cache-miss) per hit.
    probe: {600, :timer.minutes(1)},
    # Inbound payment-provider webhooks. The provider delivers from a small egress
    # IP set and can burst (a dunning run, a redelivery backfill), so the tight
    # `:form` bucket would silently drop real events — and a dropped entitlement
    # event is a paying member locked out. Generous per IP; the real authorization
    # is the HMAC signature, not the rate limit.
    billing_webhook: {300, :timer.minutes(1)}
  }

  @doc false
  # Test seam: the shipped limits, before the test env's overrides. Nothing in
  # production should read this — `limits/0` is the effective policy. It exists
  # so the suite can still pin the numbers the threat model states for the
  # buckets it also has to raise in order to run (#715).
  @spec default_limits() :: %{atom() => {pos_integer(), pos_integer()}}
  def default_limits, do: @default_limits

  @doc """
  Effective per-bucket limits: the defaults, with any per-bucket overrides from
  `config :kiln_cms, KilnCMSWeb.RateLimit, limits: %{bucket => {limit, scale}}`
  merged over them. Production leaves this unset (the defaults apply); the test
  env raises the buckets the broad controller suites hammer (`:api` etc.) so a
  fast full-suite run doesn't saturate one per-IP window and 429 unrelated tests.
  """
  def limits do
    case configured_limits() do
      # No override (production default): return the constant, no per-request
      # merge/allocation on this hot-path plug.
      empty when map_size(empty) == 0 -> @default_limits
      overrides -> Map.merge(@default_limits, overrides)
    end
  end

  defp configured_limits do
    Application.get_env(:kiln_cms, __MODULE__, []) |> Keyword.get(:limits, %{})
  end

  # A client whose address the transport did not report. Not an address, so it
  # cannot collide with one — every such caller shares one budget, which is the
  # safe reading of "we do not know who this is".
  @unknown_client "unknown"

  @doc """
  The bucket key for a client address.

  One function so that every caller spells an address the same way: the plug
  keys on `conn.remote_ip`, and `KilnCMSWeb.SignInLive` keys on an address
  resolved from a socket handshake (#715). Those two must produce the same
  string for the same client, or the shared `:auth` bucket is two buckets.
  """
  @spec client_key(:inet.ip_address() | nil) :: String.t()
  def client_key(nil), do: @unknown_client

  def client_key(address) do
    # `:inet.ntoa/1` answers `{:error, :einval}` rather than raising on anything
    # that is not an address tuple. This runs on a public page's hot path, so
    # the miss shares the unknown bucket instead of 500ing the request.
    case :inet.ntoa(address) do
      formatted when is_list(formatted) -> to_string(formatted)
      _invalid -> @unknown_client
    end
  end

  @doc "Returns `:allow` or `{:deny, retry_after_ms}` for the given bucket key."
  def check(bucket, remote_ip) when is_atom(bucket) and is_binary(remote_ip) do
    {limit, scale} = Map.fetch!(limits(), bucket)

    case hit(bucket_key(bucket, remote_ip), scale, limit) do
      {:allow, _count} -> :allow
      {:deny, retry_after} -> {:deny, retry_after}
    end
  end

  defp bucket_key(bucket, remote_ip), do: "#{bucket}:#{remote_ip}"
end
