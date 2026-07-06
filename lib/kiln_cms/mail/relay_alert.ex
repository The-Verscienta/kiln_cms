defmodule KilnCMS.Mail.RelayAlert do
  @moduledoc """
  A single aggregated alert when outbound mail can't reach the relay / MX.

  Most transient delivery failures are normal — greylisting rejects a first
  attempt, a blip retries — and stay quiet. But a *connection-class* failure
  (DNS `:nxdomain`, refused or timed-out TCP, no reachable MX; see
  `KilnCMS.Mail` for the classifier) means the relay itself is down, and *every*
  queued mail job will grind through its full ~16h retry schedule until it
  recovers. `notify/1` raises one `Logger.error` + `Sentry` message the first
  time that's seen, then stays quiet for `@cooldown` — so an outage produces one
  actionable alert instead of one per attempt per recipient.

  Backed by a Hammer fixed-window bucket (the pattern `KilnCMSWeb.RateLimit`
  uses), started in the supervision tree so the ETS table exists. The alert is
  best-effort: `notify/1` never raises into the delivery path.
  """
  use Hammer, backend: :ets

  require Logger

  # One alert per this window while an outage persists. The Hammer bucket is a
  # single fixed key, so the ETS table holds one row regardless of volume.
  @cooldown :timer.minutes(15)
  @bucket "mail:relay-unreachable"

  @doc """
  Emit the relay-unreachable alert unless one already fired within the cooldown
  window. `domain` is the recipient domain (never a full address — it reaches
  Sentry/log sinks). Always returns `:ok`.
  """
  @spec notify(String.t()) :: :ok
  def notify(domain) when is_binary(domain) do
    case hit(@bucket, @cooldown, 1) do
      {:allow, _count} -> fire(domain)
      {:deny, _retry_after_ms} -> :ok
    end
  rescue
    # Alerting must never mask or replace the delivery outcome (mirrors the
    # best-effort discipline of KilnCMS.Mail.suppress_recipients/2).
    _error -> :ok
  end

  @doc false
  # Test seam: clear the cooldown so a deterministic alert can be asserted.
  @spec reset() :: :ok
  def reset do
    _ = set(@bucket, @cooldown, 0)
    :ok
  end

  defp fire(domain) do
    message =
      "Mail relay unreachable: connection-class delivery failures (DNS/TCP/no " <>
        "MX) — outbound mail is not being delivered and every queued job will " <>
        "retry for ~16h. Latest affected recipient domain: #{domain}."

    Logger.error(message)

    # A message (not an exception), so KilnCMS.SentryFilter passes it through
    # even though it drops the per-attempt TransientDeliveryError noise. The
    # fixed fingerprint groups the whole outage into one Sentry issue rather
    # than one per affected domain. No-op when SENTRY_DSN is unset.
    Sentry.capture_message(message,
      level: :error,
      fingerprint: ["mail-relay-unreachable"],
      tags: %{component: "mail", failure_class: "relay_unreachable"}
    )

    :telemetry.execute([:kiln_cms, :mail, :relay_unreachable], %{count: 1}, %{domain: domain})

    :ok
  end
end
