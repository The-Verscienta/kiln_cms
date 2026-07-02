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

  require Logger

  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Mailer

  resources do
    resource KilnCMS.Mail.Settings do
      define :generate_dkim, action: :generate_dkim
      define :rotate_dkim, action: :rotate_dkim

      define :configure_dkim_key_source,
        action: :configure_key_source,
        args: [:provider, {:optional, :config}]

      define :set_mail_server_ip, action: :set_server_ip
      define :record_mail_verification, action: :record_verification
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

    if email.to == [] do
      raise ArgumentError, "email has no recipients"
    end

    Enum.each(email.to, fn recipient ->
      email
      |> serialize(recipient)
      |> DeliveryWorker.new()
      |> Oban.insert!()
    end)

    :ok
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
        if permanent_failure?(reason) do
          :telemetry.execute(
            [:kiln_cms, :mail, :bounced],
            %{count: 1},
            # Recipient domains only — full addresses are PII and telemetry
            # metadata may reach Sentry/OTLP exporters.
            %{recipient_domains: recipient_domains(email), reason: inspect(reason)}
          )

          {:cancel, "permanent delivery failure: #{inspect(reason)}"}
        else
          raise TransientDeliveryError,
            message: "transient delivery failure: #{inspect(reason)}"
        end
    end
  end

  ## Mail settings / DKIM

  @dkim_cache_key {__MODULE__, :dkim_config}

  @doc """
  The settings singleton, or nil before first use. A system read
  (`authorize?: false`): the admin-only policy guards the UI path, while the
  delivery pipeline and DNS checks read config actorlessly.
  """
  @spec get_settings() :: KilnCMS.Mail.Settings.t() | nil
  def get_settings do
    KilnCMS.Mail.Settings
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  @doc "The settings singleton, created on first call."
  @spec ensure_settings!() :: KilnCMS.Mail.Settings.t()
  def ensure_settings! do
    get_settings() || create_settings!()
  end

  defp create_settings! do
    KilnCMS.Mail.Settings
    |> Ash.Changeset.for_create(:init, %{})
    |> Ash.create!(authorize?: false)
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

  The computed value is cached in `:persistent_term` (settings mutations
  invalidate via `invalidate_dkim_cache/0`); set
  `config :kiln_cms, KilnCMS.Mail, cache_dkim?: false` to disable (test env,
  where async sandboxes must not share a process-global cache).
  """
  @spec dkim_config() :: keyword() | nil
  def dkim_config do
    if dkim_cache_enabled?() do
      case :persistent_term.get(@dkim_cache_key, :miss) do
        :miss ->
          value = compute_dkim_config()
          :persistent_term.put(@dkim_cache_key, value)
          value

        value ->
          value
      end
    else
      compute_dkim_config()
    end
  end

  @doc "Drop the cached DKIM options (called after settings mutations)."
  def invalidate_dkim_cache do
    :persistent_term.erase(@dkim_cache_key)
    :ok
  end

  defp compute_dkim_config do
    settings = get_settings()

    with %{dkim_selector: selector} when is_binary(selector) <- settings,
         domain when is_binary(domain) <- sending_domain() do
      case KilnCMS.Keys.fetch(:dkim) do
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

  defp dkim_cache_enabled? do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:cache_dkim?, true)
  end

  defp sending_domain do
    case Application.get_env(:kiln_cms, :email_from) do
      {_name, address} -> address |> String.split("@") |> List.last()
      _unset -> nil
    end
  end

  @doc """
  Retry delay for mail workers: `attempt` is 1-based; attempts past the table
  reuse its last entry.
  """
  @spec backoff_seconds(pos_integer()) :: pos_integer()
  def backoff_seconds(attempt) when is_integer(attempt) and attempt >= 1 do
    Enum.at(@backoff_seconds, attempt - 1, List.last(@backoff_seconds))
  end

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

  defp serialize(email, recipient) do
    %{
      "from" => address_args(email.from),
      "to" => address_args(recipient),
      "reply_to" => address_args(email.reply_to),
      "subject" => email.subject,
      "html_body" => email.html_body,
      "text_body" => email.text_body,
      # Message-ID is stamped at enqueue time so Oban retries of the same job
      # re-send the same message rather than a "new" one, and each recipient's
      # job (a distinct message) gets its own ID. Receivers score messages
      # without one as spam; the domain must match the sender.
      "headers" => Map.put_new(email.headers, "Message-ID", message_id(email))
    }
  end

  defp message_id(%Swoosh.Email{from: {_name, from_address}}) do
    domain = from_address |> String.split("@") |> List.last()
    "<#{Ecto.UUID.generate()}@#{domain}>"
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
    |> Enum.map(fn {_name, address} -> address |> String.split("@") |> List.last() end)
    |> Enum.uniq()
  end

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
end
