defmodule KilnCMS.SentryFilter do
  @moduledoc """
  `before_send` hook (wired in `config/config.exs`): drops Sentry events we
  deliberately don't want to raise as issues, and passes everything else
  through unchanged.

  Transient mail-delivery failures (`KilnCMS.Mail.TransientDeliveryError`) are
  raised *by design* so Oban retries: greylisting rejects the first attempt of
  a legitimate send, and a relay/DNS blip resolves on its own over the backoff
  schedule. With the Oban integration reporting every attempt, a single flaky
  recipient — or one relay outage fanned across every queued job — would bury
  real issues under expected retry noise.

  The systemic case that *is* worth a page — the relay / recipient MX being
  unreachable — is surfaced once, aggregated, by `KilnCMS.Mail.RelayAlert` via
  `Sentry.capture_message/2`. That's a message (its `original_exception` is
  `nil`), not a `TransientDeliveryError`, so it passes this filter.
  """
  alias KilnCMS.Mail.TransientDeliveryError

  @doc """
  Return the event to report it, or `nil`/`false` to drop it (see
  `t:Sentry.before_send_event_callback/0`).
  """
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def before_send(%Sentry.Event{original_exception: %TransientDeliveryError{}}), do: nil
  def before_send(%Sentry.Event{} = event), do: event
end
