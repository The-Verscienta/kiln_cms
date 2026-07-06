defmodule KilnCMS.Mail do
  @moduledoc """
  Entry point for outbound email delivery.

  Application code builds a `Swoosh.Email` and hands it to `enqueue!/1`, which
  inserts one `KilnCMS.Mail.DeliveryWorker` Oban job per recipient on the
  `:mail` queue instead of delivering inline. Queueing keeps the SMTP dialog
  out of the triggering request/Ash action (registration no longer blocks on
  relay latency), and is a prerequisite for direct-to-MX delivery
  (`docs/direct-email-delivery-plan.md`), where greylisting rejects first
  attempts by design and delivery must retry over minutes to hours.

  One job per recipient keeps retry state independent per recipient domain:
  one domain greylisting must not re-send to a domain that already accepted.

  `deliver_for_worker/2` is the shared delivery step for mail workers
  (`DeliveryWorker`, `KilnCMS.Notifications.WorkflowMailWorker`): it maps SMTP
  outcomes onto Oban semantics — permanent (5xx) failures cancel the job and
  emit a `[:kiln_cms, :mail, :bounced]` telemetry event, transient failures
  (4xx, connection/DNS errors) raise so Oban retries with `backoff_seconds/1`.

  Also the Ash domain for instance-wide mail settings (`KilnCMS.Mail.Settings`
  — the DKIM key reference and direct-delivery state). `dkim_config/0`
  resolves the signing key through `KilnCMS.Keys` for the DirectMX adapter.
  """
  use Ash.Domain

  require Ecto.Query
  require Logger

  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Mail.RelayAlert
  alias KilnCMS.Mailer

  resources do
    resource KilnCMS.Mail.Settings do
      define :init_settings, action: :init
      define :list_settings, action: :read
      define :generate_dkim, action: :generate_dkim
      define :rotate_dkim, action: :rotate_dkim

      define :configure_dkim_key_source,
        action: :configure_key_source,
        args: [:provider, {:optional, :config}]

      define :set_mail_server_ip, action: :set_server_ip
      define :record_mail_verification, action: :record_verification
    end

    resource KilnCMS.Mail.SuppressedRecipient do
      define :suppress_recipient, action: :suppress
      define :list_suppressed_recipients, action: :read
      define :get_suppressed_recipient, action: :read, get_by: [:email]
      define :unsuppress_recipient, action: :destroy
    end
  end

  defmodule TransientDeliveryError do
    @moduledoc """
    Raised inside mail workers for retryable delivery failures (4xx SMTP
    replies, connection resets, DNS errors) so Oban re-attempts the job.
    """
    defexception [:message]
  end

  # Greylisting windows are minutes; the tail covers relay/MX outages. Jobs
  # run `max_attempts: 8`, so the last attempt lands ~16h after the first.
  @backoff_seconds [60, 300, 900, 3600, 7200, 14_400, 28_800]

  @doc """
  Queue an email for delivery, one Oban job per `:to` recipient.

  Attachments and cc/bcc are rejected: no caller needs them today, and the
  per-recipient job split would silently change cc/bcc semantics. Lift the
  restriction deliberately when a real use case arrives.
  """
  @spec enqueue!(Swoosh.Email.t()) :: :ok
  def enqueue!(%Swoosh.Email{} = email) do
    if email.attachments != [] do
      raise ArgumentError, "KilnCMS.Mail does not support attachments yet"
    end

    if email.cc != [] or email.bcc != [] do
      raise ArgumentError, "KilnCMS.Mail does not support cc/bcc yet"
    end

    if email.provider_options != %{} do
      # Provider options don't survive the Oban args round-trip; reject them
      # explicitly (like attachments/cc/bcc) rather than dropping them silently.
      raise ArgumentError, "KilnCMS.Mail does not support provider_options yet"
    end

    if email.to == [] do
      raise ArgumentError, "email has no recipients"
    end

    Enum.each(email.to, fn {_name, address} ->
      unless valid_address?(address) do
        raise ArgumentError, "invalid recipient address: #{inspect(address)}"
      end
    end)

    email.to
    # Drop recipients that previously hard-bounced: re-attempting a dead
    # address wastes retries and signals spamminess. An admin clears the
    # suppression from /editor/mail to resume.
    |> Enum.reject(fn {_name, address} -> suppressed?(address) end)
    |> Enum.each(fn recipient ->
      email
      |> serialize(recipient)
      |> DeliveryWorker.new()
      |> Oban.insert!()
    end)

    :ok
  end

  @doc """
  Recent mail jobs that ended in a permanent failure (`cancelled` = hard 5xx)
  or exhausted retries (`discarded`), newest first — for the admin delivery
  panel. Returns maps with the recipient **domain** (never the full address),
  state, timestamp, and the already-redacted reason.
  """
  @spec recent_delivery_failures(pos_integer()) :: [map()]
  def recent_delivery_failures(limit \\ 20) do
    Ecto.Query.from(j in Oban.Job,
      where: j.queue == "mail" and j.state in ["cancelled", "discarded"],
      order_by: [desc: j.attempted_at],
      limit: ^limit
    )
    |> KilnCMS.Repo.all()
    |> Enum.map(&summarize_failure/1)
  end

  defp summarize_failure(job) do
    %{
      domain: failure_domain(job.args),
      state: job.state,
      at: job.attempted_at,
      reason: last_error(job.errors)
    }
  end

  defp failure_domain(%{"to" => [_name, address]}) when is_binary(address), do: domain_of(address)
  defp failure_domain(_args), do: "unknown"

  defp last_error(errors) when is_list(errors) do
    case List.last(errors) do
      %{"error" => error} -> error
      _other -> nil
    end
  end

  defp last_error(_errors), do: nil

  @doc "Whether `address` is on the bounce-suppression list (case-insensitive)."
  @spec suppressed?(String.t()) :: boolean()
  def suppressed?(address) do
    # Bang variant returns the record or nil directly; the non-bang one wraps
    # it in `{:ok, _}`, which would read as "always suppressed".
    case get_suppressed_recipient!(address, authorize?: false, not_found_error?: false) do
      nil -> false
      _record -> true
    end
  end

  # Suppress every recipient of a hard-bounced message. Best-effort: a failure
  # to record must not mask the delivery outcome, so the result is ignored and
  # any unexpected raise is swallowed.
  defp suppress_recipients(email, reason) do
    Enum.each(email.to, fn {_name, address} ->
      _ = suppress_recipient(%{email: address, reason: reason}, authorize?: false)
    end)
  rescue
    _error -> :ok
  end

  @doc """
  Deliver an email from inside an Oban worker, translating the outcome into
  Oban return values: `:ok` on success, `{:cancel, reason}` on a permanent
  (5xx) failure, raises `TransientDeliveryError` otherwise so the job retries.

  `config` is merged over the mailer config (tests inject failing adapters).
  """
  @spec deliver_for_worker(Swoosh.Email.t(), keyword()) :: :ok | {:cancel, String.t()}
  def deliver_for_worker(%Swoosh.Email{} = email, config \\ []) do
    case Mailer.deliver(email, config) do
      {:ok, _receipt} ->
        :ok

      {:error, reason} ->
        safe_reason = redact_reason(reason)

        if permanent_failure?(reason) do
          cancel_permanent(email, safe_reason)
        else
          retry_transient(email, reason, safe_reason)
        end
    end
  end

  # A hard 5xx: log + emit a bounce event + suppress the address, then cancel.
  defp cancel_permanent(email, safe_reason) do
    # Log so a systematic 5xx (e.g. a rotated relay password) is visible in
    # server logs and Sentry, not just as `cancelled` rows in `oban_jobs` — a
    # cancel is otherwise silent (no job exception, and Sentry's Oban
    # integration ignores `{:cancel, _}`).
    Logger.warning(
      "Mail permanently rejected for #{Enum.join(recipient_domains(email), ", ")}, " <>
        "cancelling: #{safe_reason}"
    )

    :telemetry.execute(
      [:kiln_cms, :mail, :bounced],
      %{count: 1},
      # Recipient domains only, and the reason is scrubbed of any address: 5xx
      # reject texts routinely echo the recipient, and this metadata (and the
      # cancel reason below) may reach Sentry/OTLP exporters.
      %{recipient_domains: recipient_domains(email), reason: safe_reason}
    )

    # Remember the dead address so future sends skip it (enqueue!).
    suppress_recipients(email, safe_reason)

    {:cancel, "permanent delivery failure: #{safe_reason}"}
  end

  # A retryable failure: raise so Oban retries. A connection-class failure (DNS,
  # refused/timed-out TCP, no reachable MX) means the relay/MX itself is down —
  # not one greylisted recipient — so surface it once, aggregated, rather than
  # one alert per attempt per recipient. Greylisting (4xx) stays quiet.
  defp retry_transient(email, reason, safe_reason) do
    if connection_class?(reason), do: RelayAlert.notify(recipient_domain(email))

    raise TransientDeliveryError, message: "transient delivery failure: #{safe_reason}"
  end

  ## Mail settings / DKIM

  @doc """
  The settings singleton, or nil before first use. A system read
  (`authorize?: false`): the admin-only policy guards the UI path, while the
  delivery pipeline and DNS checks read config actorlessly.
  """
  @spec get_settings() :: KilnCMS.Mail.Settings.t() | nil
  def get_settings do
    # The row is a singleton (unique `singleton` column), so a bare read
    # returns at most one record.
    case list_settings!(authorize?: false) do
      [settings | _rest] -> settings
      [] -> nil
    end
  end

  @doc "The settings singleton, created on first call."
  @spec ensure_settings!() :: KilnCMS.Mail.Settings.t()
  def ensure_settings! do
    get_settings() || create_settings!()
  end

  defp create_settings! do
    init_settings!(%{}, authorize?: false)
  rescue
    # Lost a concurrent-creation race on the singleton identity: the row
    # exists now, so read it.
    e in [Ash.Error.Invalid, Ash.Error.Unknown] ->
      get_settings() || reraise(e, __STACKTRACE__)
  end

  @doc """
  DKIM signing options for `KilnCMS.Mailer.DirectMX`, in the shape gen_smtp's
  MIME encoder expects (`[s: selector, d: domain, private_key: ...]`), with
  the key material resolved through `KilnCMS.Keys` and the domain taken from
  the configured From address.

  `nil` — unsigned sends — when no key is configured, and (with a logged
  warning) when a configured key can't be resolved: losing the signature
  hurts deliverability, losing the email loses a password reset.

  Computed fresh per call from a single settings read. There is deliberately
  no process-global cache: an outbound mail job is already an async network
  round-trip, so one indexed read plus a key resolution is negligible against
  the SMTP dialog — and a cache invites a rotation race (a stale selector/key
  cached after invalidation), pins an error-produced `nil` until restart, and
  goes stale on other cluster nodes. Correctness beats the microseconds.
  """
  @spec dkim_config() :: keyword() | nil
  def dkim_config do
    with %{dkim_selector: selector} = settings when is_binary(selector) <- get_settings(),
         domain when is_binary(domain) <- sending_domain() do
      # Resolve the key from the same row we just read, so the selector and the
      # key material are always from one consistent snapshot.
      case KilnCMS.Keys.fetch_for(settings) do
        {:ok, pem} ->
          [s: selector, d: domain, private_key: {:pem_plain, pem}]

        {:error, reason} ->
          Logger.warning(
            "DKIM key configured but unresolvable, sending unsigned: " <>
              KilnCMS.Keys.describe_error(reason)
          )

          nil
      end
    else
      _not_configured -> nil
    end
  end

  @doc """
  The domain mail is sent from (and DKIM-signed for) — the domain of the
  configured From address, or nil when `:email_from` is unset.
  """
  @spec sending_domain() :: String.t() | nil
  def sending_domain do
    case Application.get_env(:kiln_cms, :email_from) do
      {_name, address} -> domain_of(address)
      _unset -> nil
    end
  end

  @doc """
  The lowercased domain part of an email address. Single source of truth so
  every consumer (DKIM `d=`, Message-ID, DirectMX per-domain grouping, bounce
  telemetry) normalizes case identically — otherwise mixed-case addresses
  split into distinct telemetry buckets and produce case-varying Message-IDs.
  """
  @spec domain_of(String.t()) :: String.t()
  def domain_of(address) when is_binary(address),
    do: address |> String.split("@") |> List.last() |> String.downcase()

  @doc """
  Deliver synchronously, bypassing the queue — the admin "send test email"
  path, where the operator wants the SMTP outcome (receipt or error) now
  instead of a retrying background job.
  """
  @spec deliver_now(Swoosh.Email.t()) :: {:ok, term()} | {:error, term()}
  def deliver_now(%Swoosh.Email{} = email), do: Mailer.deliver(email)

  @doc """
  Retry delay for mail workers: `attempt` is 1-based; attempts past the table
  reuse its last entry.
  """
  @spec backoff_seconds(pos_integer()) :: pos_integer()
  def backoff_seconds(attempt) when is_integer(attempt) and attempt >= 1 do
    Enum.at(@backoff_seconds, attempt - 1, List.last(@backoff_seconds))
  end

  @doc """
  Per-attempt wall-clock ceiling for mail workers (`Oban.Worker.timeout/1`).

  gen_smtp bounds the TCP *connect* at 5s, but its per-command read timeout is
  a hardcoded 20 minutes with no config seam — so a relay that accepts the
  connection and then tarpits (greylist tarpitting, a wedged MX, a firewall
  dropping mid-stream) would hold a `:mail` queue slot for up to that long. A
  60s ceiling turns any such hang into a fast failed attempt that retries on
  `backoff_seconds/1`, so one bad relay can't starve the queue. Generous for a
  healthy dialog (connect + STARTTLS + DATA complete in well under a second).
  """
  @spec attempt_timeout() :: pos_integer()
  def attempt_timeout, do: :timer.seconds(60)

  @doc """
  Rebuild a `Swoosh.Email` from `serialize/2` output (Oban args, so keys are
  strings and address tuples became two-element lists).
  """
  @spec from_args(map()) :: Swoosh.Email.t()
  def from_args(%{"from" => from, "to" => to, "subject" => subject} = args) do
    import Swoosh.Email

    new()
    |> from(address(from))
    |> to(address(to))
    |> subject(subject)
    |> maybe(&reply_to/2, address(args["reply_to"]))
    |> maybe(&html_body/2, args["html_body"])
    |> maybe(&text_body/2, args["text_body"])
    |> headers(args["headers"] || %{})
  end

  @doc """
  Stamp a `Message-ID` header on `email` unless it already has one.

  Receivers score messages without a Message-ID as spam, and gen_smtp
  otherwise auto-fills one from the local (container) hostname, which won't
  match the From domain. Pass `token` to make the ID stable across retries
  that rebuild the same email (e.g. a worker keying on its Oban job id);
  omit it for a fresh random ID.
  """
  @spec ensure_message_id(Swoosh.Email.t(), String.t() | nil) :: Swoosh.Email.t()
  def ensure_message_id(%Swoosh.Email{headers: headers} = email, token \\ nil) do
    if Map.has_key?(headers, "Message-ID") do
      email
    else
      Swoosh.Email.header(email, "Message-ID", message_id(email, token))
    end
  end

  defp serialize(email, recipient) do
    # Stamp the Message-ID here (at enqueue time) so Oban retries of the same
    # job re-send the same message rather than a "new" one; each recipient's
    # job is a distinct message and gets its own ID.
    email = ensure_message_id(email)

    %{
      "from" => address_args(email.from),
      "to" => address_args(recipient),
      "reply_to" => address_args(email.reply_to),
      "subject" => email.subject,
      "html_body" => email.html_body,
      "text_body" => email.text_body,
      "headers" => email.headers
    }
  end

  defp message_id(email, token) do
    id = token || Ecto.UUID.generate()
    "<#{id}@#{message_domain(email)}>"
  end

  # Prefer the From domain (the domain a DKIM signature and SPF align to);
  # fall back to the configured sending domain, then a last-resort literal so
  # a from-less email still gets a syntactically valid ID instead of crashing.
  defp message_domain(%Swoosh.Email{from: {_name, address}}) when is_binary(address),
    do: domain_of(address)

  defp message_domain(_email), do: sending_domain() || "localhost"

  # A minimally-valid address has exactly one "@" with non-empty local and
  # domain parts. Guards against a malformed recipient becoming the SMTP relay
  # in DirectMX (where the whole string would be MX-looked-up and retried for
  # hours as a "transient" DNS failure).
  defp valid_address?(address) when is_binary(address) do
    case String.split(address, "@") do
      [local, domain] -> local != "" and domain != "" and not String.contains?(domain, " ")
      _ -> false
    end
  end

  defp valid_address?(_address), do: false

  # Scrub anything address-shaped from an inspected error term so recipient
  # PII in 5xx reject texts doesn't leak into telemetry, logs, or the stored
  # Oban cancel reason. Keeps the structure/SMTP status useful for debugging.
  defp redact_reason(reason) do
    reason
    |> inspect()
    |> String.replace(~r/[\w.!#$%&'*+\/=?^`{|}~-]+@[\w.-]+/, "[address redacted]")
  end

  defp address_args(nil), do: nil
  defp address_args({name, address}), do: [name, address]

  defp address(nil), do: nil
  defp address([name, address]), do: {name, address}

  defp maybe(email, _fun, nil), do: email
  defp maybe(email, fun, value), do: fun.(email, value)

  defp headers(email, headers) do
    Enum.reduce(headers, email, fn {name, value}, acc ->
      Swoosh.Email.header(acc, name, value)
    end)
  end

  defp recipient_domains(email) do
    email.to
    |> Enum.map(fn {_name, address} -> domain_of(address) end)
    |> Enum.uniq()
  end

  # enqueue!/1 splits one job per recipient, so a delivery targets a single
  # domain; join defensively in case a caller delivered a multi-recipient email.
  defp recipient_domain(email), do: email |> recipient_domains() |> Enum.join(", ")

  # gen_smtp reports hard rejects as a `:permanent_failure` marker nested at
  # varying depths (`{:no_more_hosts, {:permanent_failure, host, msg}}`,
  # `{:send, {:permanent_failure, ...}}`, ...) depending on where in the
  # dialog the 5xx arrived, so walk the term rather than enumerate shapes.
  # Anything else — 4xx, network errors, unexpected shapes — is treated as
  # transient: retrying a hard bounce a few times is wasteful but harmless,
  # while cancelling a greylisted send loses the email.
  defp permanent_failure?(:permanent_failure), do: true

  defp permanent_failure?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&permanent_failure?/1)

  defp permanent_failure?(term) when is_list(term),
    do: Enum.any?(term, &permanent_failure?/1)

  defp permanent_failure?(_term), do: false

  # A transient failure is "connection-class" when delivery never reached an
  # SMTP dialog — DNS resolution, TCP connect, or the connection dropping —
  # rather than an SMTP-level 4xx (greylisting, which gen_smtp marks
  # `:temporary_failure`). gen_smtp nests `:network_failure` and the underlying
  # posix atom at varying depths (`{:retries_exceeded, {:network_failure, host,
  # {:error, :nxdomain}}}`, `{:network_failure, {:error, :econnrefused}}`, ...),
  # so walk the term like `permanent_failure?/1`. Keyed on `:network_failure`
  # (present for every socket/DNS error, absent from a `:temporary_failure`
  # greylist) plus the posix atoms as defence in depth.
  @connection_class_markers ~w(
    network_failure
    nxdomain econnrefused econnreset ehostunreach enetunreach etimedout ehostdown
  )a

  defp connection_class?(marker) when is_atom(marker), do: marker in @connection_class_markers

  defp connection_class?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&connection_class?/1)

  defp connection_class?(term) when is_list(term),
    do: Enum.any?(term, &connection_class?/1)

  defp connection_class?(_term), do: false
end
