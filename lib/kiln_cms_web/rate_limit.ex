defmodule KilnCMSWeb.RateLimit do
  @moduledoc """
  ETS-backed rate limiter for API and auth endpoints (Hammer fixed window).
  """
  use Hammer, backend: :ets

  @limits %{
    gql: {60, :timer.minutes(1)},
    api: {120, :timer.minutes(1)},
    auth: {20, :timer.minutes(1)},
    # Public HTML delivery — generous, just a flood/abuse ceiling per IP.
    delivery: {300, :timer.minutes(1)},
    # Signed preview links — tight, to slow token enumeration / draft scraping.
    preview: {30, :timer.minutes(1)},
    # Always-on Swagger UI explorer (#225) — generous for human browsing, caps
    # crawler/abuse traffic against the docs UI.
    docs: {60, :timer.minutes(1)}
  }

  @doc false
  def limits, do: @limits

  @doc "Returns `:allow` or `{:deny, retry_after_ms}` for the given bucket key."
  def check(bucket, remote_ip) when is_atom(bucket) and is_binary(remote_ip) do
    {limit, scale} = Map.fetch!(@limits, bucket)
    key = "#{bucket}:#{remote_ip}"

    case hit(key, scale, limit) do
      {:allow, _count} -> :allow
      {:deny, retry_after} -> {:deny, retry_after}
    end
  end
end
