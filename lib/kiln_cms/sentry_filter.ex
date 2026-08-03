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

  ## Malformed LiveView joins (#700)

  A `/live` join whose payload carries a **non-binary** `"url"` or `"redirect"`
  crashes before any mount hook runs. Phoenix.LiveView.Channel calls
  `authorize_session/3` outside the `try/rescue` that turns a 4xx into a clean
  client reload, and Phoenix.LiveView.Route.live_link_info_without_checks/3
  accepts only a binary or a `%URI{}` — so `%{"url" => nil}` or `%{"url" => 42}`
  is a `FunctionClauseError`, a `GenServer terminating` report, and one Sentry
  event *per attempt*.

  How much that costs is worth stating accurately, because it sizes the trade.
  Sentry.Dedupe is on by default and already collapses this: every input to
  its hash is constant across attempts — Sentry never calls `Exception.blame/3`,
  so the message is the same string for `nil`, `42` and `%{}` alike, and the
  stacktrace, level, fingerprint and tags do not vary either. Its 30-second TTL
  is refreshed on each hit, so a sustained flood is roughly *one* event, not one
  per attempt.

  What the filter buys is therefore narrower than "stops a quota burn": it skips
  building an event per attempt and the "dropped as duplicate" log line per
  attempt, and — the part that matters — it stops a caller *choosing* to emit a
  real-looking issue at all. The credential is a signed `data-phx-session` blob
  scraped from any page the caller was legitimately served, the payload is one
  field, and socket joins have no limiter, so the alternative is one genuine
  issue sitting in the tracker for as long as someone cares to keep it there.

  Dropping the event does not pretend the crash isn't happening: the local
  `GenServer terminating` report is untouched, and an operator investigating
  still sees it. What it stops is a caller choosing how much of the error
  budget to spend.

  Deliberately narrow — this one function, on this one module.
  Phoenix.LiveView.Route.live_link_info_without_checks/3
  is the framework's own routing helper and nothing in Kiln calls it, so a
  `FunctionClauseError` from it is always this shape. A broader filter (any
  `FunctionClauseError`, or anything from Phoenix.LiveView.Channel) would
  swallow real LiveView bugs, which is the opposite of the point. The fix
  belongs upstream, where the catch-all could reject a non-binary `"url"`
  rather than falling through to a function clause; until then this is the
  cheapest thing that does not lie.
  """
  alias KilnCMS.Mail.TransientDeliveryError

  @join_module Phoenix.LiveView.Route
  @join_function :live_link_info_without_checks
  @join_arity 3

  @doc """
  Return the event to report it, or `nil`/`false` to drop it (see
  `t:Sentry.before_send_event_callback/0`).
  """
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def before_send(%Sentry.Event{original_exception: %TransientDeliveryError{}}), do: nil

  def before_send(%Sentry.Event{
        original_exception: %FunctionClauseError{
          module: @join_module,
          function: @join_function,
          arity: @join_arity
        }
      }),
      do: nil

  def before_send(%Sentry.Event{} = event), do: event
end
