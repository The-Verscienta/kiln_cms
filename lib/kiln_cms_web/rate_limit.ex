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
    probe: {600, :timer.minutes(1)}
  }

  @doc """
  Effective per-bucket limits: the defaults, with any per-bucket overrides from
  `config :kiln_cms, KilnCMSWeb.RateLimit, limits: %{bucket => {limit, scale}}`
  merged over them. Production leaves this unset (the defaults apply); the test
  env raises the buckets the broad controller suites hammer (`:api` etc.) so a
  fast full-suite run doesn't saturate one per-IP window and 429 unrelated tests.
  """
  def limits, do: Map.merge(@default_limits, configured_limits())

  defp configured_limits do
    Application.get_env(:kiln_cms, __MODULE__, []) |> Keyword.get(:limits, %{})
  end

  @doc "Returns `:allow` or `{:deny, retry_after_ms}` for the given bucket key."
  def check(bucket, remote_ip) when is_atom(bucket) and is_binary(remote_ip) do
    {limit, scale} = Map.fetch!(limits(), bucket)
    key = "#{bucket}:#{remote_ip}"

    case hit(key, scale, limit) do
      {:allow, _count} -> :allow
      {:deny, retry_after} -> {:deny, retry_after}
    end
  end
end
