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

  ## Job arguments: mail bodies (#1843) and private args (#2992)

  Every event that passes is scrubbed of what a job's args must not carry out
  of the deployment. Sentry's Oban integration attaches the failing job's
  `args` as the event's `extra`:

    * a mail job's args hold the message — sealed since 1.0
      (`KilnCMS.Mail.open_args/1`), in the clear in a job queued earlier —
      which for a password reset or a newsletter confirmation is a live
      sign-in link. The body keys are dropped from `extra.args`, and a
      message or exception value that quotes a rendered `%Swoosh.Email{}` (an
      adapter crash, before the delivery path stopped recording them) is
      replaced whole;
    * a job of a worker `KilnCMS.Jobs.PrivateArgs` registers (form mail
      jobs queued before #2992, automation jobs, workflow and task mail jobs
      queued before #3019) holds a visitor's submission, a document snapshot,
      or a recipient's address and what the mail quoted. Its registered
      keys are dropped from `extra.args`, named by `extra.worker`. The
      variables of every stack frame are dropped too: a `FunctionClauseError`
      in the worker's own helpers quotes their arguments there, and those are
      the same payload (or, for a mail job of the current shape, the
      recipient's account it read back).

  ## URLs and process dumps

  The request URL and a `Referer` header have their credential path segments
  and query parameters filtered (`KilnCMSWeb.UrlRedaction`), and so do the
  `genserver_state` and `last_message` a crash report carries: every URL,
  quoted path or query string in them, and every quoted value under a
  credential-named key.
  """
  alias KilnCMS.Jobs.PrivateArgs
  alias KilnCMS.Mail
  alias KilnCMS.Mail.TransientDeliveryError
  alias KilnCMSWeb.UrlRedaction

  @process_dumps [:genserver_state, :last_message, "genserver_state", "last_message"]

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

  def before_send(%Sentry.Event{} = event), do: scrub_mail(event)

  @email_dump ~r/%Swoosh\.Email\{|html_body|text_body/
  @withheld "[mail message withheld]"

  defp scrub_mail(%Sentry.Event{} = event) do
    event = scrub_frames(event)

    %{
      event
      | extra: scrub_extra(event.extra),
        message: scrub_message(event.message),
        exception: scrub_exceptions(event.exception),
        request: scrub_request(event.request)
    }
  end

  # `Sentry.PlugContext` copies the raw query string into the event and takes
  # no scrubber for it, so a credential presented as `?preview_token=` or
  # `?unlock=` (#1887) would reach Sentry verbatim. Masked here, with the body
  # scrubber's own rule.
  #
  # The URL and a `Referer` are redacted here as well as in
  # `KilnCMSWeb.SentryScrubber` (`url_scrubber`, `header_scrubber`): this is
  # the last step before an event leaves, so a request context set by any
  # other path is covered too.
  defp scrub_request(%Sentry.Interfaces.Request{query_string: query} = request) do
    %{
      request
      | query_string: KilnCMSWeb.SentryScrubber.scrub_query_string(query),
        url: scrub_url(request.url),
        headers: KilnCMSWeb.SentryScrubber.redact_referer(request.headers)
    }
  end

  defp scrub_request(request), do: request

  defp scrub_url(url) when is_binary(url), do: UrlRedaction.url(url)
  defp scrub_url(url), do: url

  defp scrub_extra(%{} = extra) do
    private = Mail.body_keys() ++ PrivateArgs.keys(worker(extra))

    Map.new(extra, fn
      {key, %{} = args} when key in [:args, "args"] -> {key, Map.drop(args, private)}
      {key, value} when key in @process_dumps -> {key, scrub_dump(value)}
      other -> other
    end)
  end

  defp scrub_extra(extra), do: extra

  # The failing job's worker, as Sentry's Oban integration records it
  # (`"KilnCMS.Automation.RuleWorker"`); nil for any other event.
  defp worker(%{worker: worker}) when is_binary(worker), do: worker
  defp worker(%{"worker" => worker}) when is_binary(worker), do: worker
  defp worker(_extra), do: nil

  # A registered worker's frames lose their variables: Sentry fills them from
  # the arguments an exception's stacktrace carries, and a clause error in the
  # worker's helpers is called with the job's payload.
  defp scrub_frames(%Sentry.Event{extra: extra} = event) when is_map(extra) do
    if PrivateArgs.registered?(worker(extra)) do
      %{
        event
        | exception: map_list(event.exception, &drop_vars/1),
          threads: map_list(event.threads, &drop_vars/1)
      }
    else
      event
    end
  end

  defp scrub_frames(event), do: event

  defp map_list(items, fun) when is_list(items), do: Enum.map(items, fun)
  defp map_list(items, _fun), do: items

  defp drop_vars(%{stacktrace: %Sentry.Interfaces.Stacktrace{frames: frames} = stacktrace} = item)
       when is_list(frames) do
    %{item | stacktrace: %{stacktrace | frames: Enum.map(frames, &%{&1 | vars: nil})}}
  end

  defp drop_vars(item), do: item

  # A crashed process's state and last message, inspected by Sentry's logger
  # handler. A LiveView's state holds the URL it joined with and its assigns,
  # and either may carry a credential from a token link.
  defp scrub_dump(value) when is_binary(value), do: UrlRedaction.text(value)

  defp scrub_dump(value) when is_list(value) do
    value |> IO.chardata_to_string() |> UrlRedaction.text()
  rescue
    _error -> UrlRedaction.filtered()
  end

  defp scrub_dump(value), do: value

  defp scrub_message(%Sentry.Interfaces.Message{} = message) do
    if dump?(message.formatted) or dump?(message.message) or
         Enum.any?(message.params || [], &dump?/1) do
      %{message | formatted: @withheld, message: @withheld, params: []}
    else
      message
    end
  end

  defp scrub_message(message), do: message

  defp scrub_exceptions(exceptions) when is_list(exceptions),
    do: Enum.map(exceptions, &scrub_exception/1)

  defp scrub_exceptions(exceptions), do: exceptions

  defp scrub_exception(%Sentry.Interfaces.Exception{value: value} = exception) do
    if dump?(value), do: %{exception | value: @withheld}, else: exception
  end

  defp scrub_exception(exception), do: exception

  defp dump?(text) when is_binary(text), do: Regex.match?(@email_dump, text)
  defp dump?(_other), do: false
end
