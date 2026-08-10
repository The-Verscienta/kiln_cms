defmodule KilnCMSWeb.TenantRefusalAlert do
  @moduledoc """
  A single aggregated alert per surface when tenant resolution refuses a
  request (#678).

  `KilnCMSWeb.Tenant.fetch_org/1` refuses under `TENANT_STRICT_HOST` (#563),
  and #677 made a repeated refusal for the *same* host cheap (cached as a
  miss in `KilnCMS.Cache.Hosts`) — but a flood of *distinct* invented hosts
  still costs a lookup each, on all five callers that resolve a tenant
  (`KilnCMSWeb.Plugs.SetTenant`, the LiveView `:assign_current_org` on_mount
  hook, and the three raw sockets), and until now none of it reached an
  operator. `notify/2` fires the first refusal on a given surface and then
  stays quiet for `@cooldown`, so a sustained flood produces one actionable
  alert per surface instead of one `Logger.debug` per rejection (still
  emitted at each call site, unthrottled, for an operator already looking).

  Backed by a Hammer fixed-window bucket per `source`, the pattern
  `KilnCMS.Mail.RelayAlert` uses, started in the supervision tree so the ETS
  table exists. Best-effort: `notify/2` never raises into the caller's own
  refusal.

  ## Where this is (and is not) called from

  Emitted from each caller's own **refusal decision**, never from
  `Tenant.fetch_org/1` or `fetch_org_from_connect_info/1` themselves — those
  are shared choke points reached by health probes and other host-agnostic
  traffic before a caller has applied its own exemption, so instrumenting
  them would count requests that were actually served. And never from
  `KilnCMSWeb.LiveUserAuth`'s foreign-claim check: that refusal is driven
  entirely by the *client's* claimed host, not by a host that failed to
  resolve, so a client could trip it for free regardless of whether its real
  connection ever failed — counting it would answer a different question
  than "is this surface being flooded" (see the #678 issue history for the
  attempt that got this wrong the first time).

  `source` is one of a fixed, small set (`:plug`, `:live`, `:gql`, `:bridge`,
  `:collab`) — bounded, unlike the host itself, so the tag can safely go in
  a Sentry fingerprint and answer which surface a flood is landing on.
  """
  use Hammer, backend: :ets

  require Logger

  @cooldown :timer.minutes(15)
  @sources ~w(plug live gql bridge collab)a

  @doc """
  Emit the refusal-flood alert for `source` unless one already fired within
  the cooldown window. `host` is the offending host (may be `nil`) — it
  reaches only the log line and Sentry, never the bucket key, so the alert
  stays one-per-surface regardless of how many distinct hosts are behind the
  flood. Always returns `:ok`.
  """
  @spec notify(atom(), String.t() | nil) :: :ok
  def notify(source, host) when source in @sources do
    case hit(bucket(source), @cooldown, 1) do
      {:allow, _count} -> fire(source, host)
      {:deny, _retry_after_ms} -> :ok
    end
  rescue
    # Alerting must never turn a refusal into a 500 (mirrors RelayAlert).
    _error -> :ok
  end

  @doc false
  # Test seam: clear every source's cooldown so a deterministic alert can be
  # asserted. Drops the whole table rather than one key, since a test wants a
  # clean slate and Hammer's `set/3` takes a `pos_integer()` count.
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(__MODULE__)
    :ok
  end

  defp bucket(source), do: "tenant_refusal:#{source}"

  defp fire(source, host) do
    message =
      "Tenant refusal flood on #{source}: repeated distinct-host refusals " <>
        "(TENANT_STRICT_HOST). The per-host cache (#677) bounds the cost of " <>
        "repeating one host, not the volume of distinct ones. Latest refused " <>
        "host: #{inspect(host)}."

    Logger.warning(message)

    Sentry.capture_message(message,
      level: :warning,
      fingerprint: ["tenant-refusal-flood", to_string(source)],
      tags: %{component: "tenant", source: to_string(source)}
    )

    :telemetry.execute([:kiln_cms, :tenant, :refusal_flood], %{count: 1}, %{source: source})

    :ok
  end
end
