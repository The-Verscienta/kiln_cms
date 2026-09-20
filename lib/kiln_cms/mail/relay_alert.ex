defmodule KilnCMS.Mail.RelayAlert do
  @moduledoc """
  A single aggregated alert when outbound mail can't reach the relay / MX, or
  the relay refuses us.

  Most transient delivery failures are normal — greylisting rejects a first
  attempt, a blip retries — and stay quiet. But a *connection-class* failure
  (DNS `:nxdomain`, refused or timed-out TCP, no reachable MX; see
  `KilnCMS.Mail` for the classifier) means the relay itself is down, and *every*
  queued mail job will grind through its full ~16h retry schedule until it
  recovers. `notify/1` raises one `Logger.error` + `Sentry` message the first
  time that's seen, then stays quiet for `@cooldown` — so an outage produces one
  actionable alert instead of one per attempt per recipient.

  `notify_refused/2` is the same alert for a relay that answers but refuses our
  side permanently — AUTH failing after a password rotation, STARTTLS, the
  sender — which `KilnCMS.Mail` retries rather than bouncing. It has its own
  cooldown, so an outage of one kind never hides the other.

  Backed by a Hammer fixed-window bucket (the pattern `KilnCMSWeb.RateLimit`
  uses), started in the supervision tree so the ETS table exists. The alert is
  best-effort: neither function raises into the delivery path.
  """
  use Hammer, backend: :ets

  require Logger

  # One alert per this window while an outage persists. Each kind is a single
  # fixed Hammer key, so the ETS table holds one row per kind regardless of
  # volume.
  @cooldown :timer.minutes(15)
  @unreachable %{
    bucket: "mail:relay-unreachable",
    fingerprint: "mail-relay-unreachable",
    event: :relay_unreachable,
    failure_class: "relay_unreachable"
  }
  @refused %{
    bucket: "mail:relay-refused",
    fingerprint: "mail-relay-refused",
    event: :relay_refused,
    failure_class: "relay_refused"
  }

  @doc """
  Emit the relay-unreachable alert unless one already fired within the cooldown
  window. `domain` is the recipient domain (never a full address — it reaches
  Sentry/log sinks). Always returns `:ok`.
  """
  @spec notify(String.t()) :: :ok
  def notify(domain) when is_binary(domain) do
    alert(
      @unreachable,
      %{domain: domain},
      "Mail relay unreachable: connection-class delivery failures (DNS/TCP/no " <>
        "MX) — outbound mail is not being delivered and every queued job will " <>
        "retry for ~16h. Latest affected recipient domain: #{domain}."
    )
  end

  @doc """
  Emit the relay-refused alert unless one already fired within the cooldown
  window. `domain` is the recipient domain and `reason` the address-redacted
  SMTP reason (both reach Sentry/log sinks). Always returns `:ok`.
  """
  @spec notify_refused(String.t(), String.t()) :: :ok
  def notify_refused(domain, reason) when is_binary(domain) and is_binary(reason) do
    alert(
      @refused,
      %{domain: domain, reason: reason},
      "Mail relay refused us: a permanent failure on our side of the SMTP " <>
        "dialog (authentication, TLS or the sender address) — outbound mail is " <>
        "not being delivered and every queued job will retry for ~16h. Check " <>
        "the relay credentials and From address. Latest reason: #{reason}; " <>
        "recipient domain: #{domain}."
    )
  end

  defp alert(kind, metadata, message) do
    case hit(kind.bucket, @cooldown, 1) do
      {:allow, _count} -> fire(kind, metadata, message)
      {:deny, _retry_after_ms} -> :ok
    end
  rescue
    # Alerting must never mask or replace the delivery outcome (mirrors the
    # best-effort discipline of KilnCMS.Mail.suppress_recipients/2).
    _error -> :ok
  end

  @doc false
  # Test seam: clear the cooldown so a deterministic alert can be asserted.
  # Drops the bucket rows outright rather than zeroing them via Hammer's
  # `set/3`, whose `count` is spec'd `pos_integer()` — passing 0 is a type
  # violation. Hammer names the ETS table after the module, and the two kinds'
  # buckets are its only keys.
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(__MODULE__)
    :ok
  end

  defp fire(kind, metadata, message) do
    Logger.error(message)

    # A message (not an exception), so KilnCMS.SentryFilter passes it through
    # even though it drops the per-attempt TransientDeliveryError noise. The
    # fixed fingerprint groups the whole outage into one Sentry issue rather
    # than one per affected domain or reason. No-op when SENTRY_DSN is unset.
    Sentry.capture_message(message,
      level: :error,
      fingerprint: [kind.fingerprint],
      tags: %{component: "mail", failure_class: kind.failure_class}
    )

    :telemetry.execute([:kiln_cms, :mail, kind.event], %{count: 1}, metadata)

    :ok
  end
end
