defmodule KilnCMS.Mail.SiteRelay do
  @moduledoc """
  Which relay a site's mail goes out through (#1322): the site's own
  (`KilnCMS.CMS.SiteMailRelay`, set at `/editor/site-mail`) or the operator's
  (`SMTP_*` / `MAIL_MODE`, the `KilnCMS.Mailer` config).

  `KilnCMS.Mail.deliver_for_worker/2` asks `route/2` once per delivery attempt.
  Mail with no site — account mail, which belongs to the deployment — never
  gets here and always uses the operator's relay.

  ## Precedence

    * The site has a row and it is switched on — **the site's relay and From
      address**, and nothing from the operator's mailer config. The connection
      is built from the row alone (`Swoosh.Mailer.deliver/2`, not
      `KilnCMS.Mailer.deliver/2`, which would merge the operator's config
      underneath). Merging would put the operator's relay password into a
      connection to a host a tenant chose, one missing key away from sending it.
    * No row, or the row is switched off — **the operator's relay**, exactly as
      before this existed. That is the site's own choice.

  ## Fail direction

  Two-layer settings have a third case: the row exists but cannot be used. The
  read failed (the pool timed out, or the table does not exist yet
  mid-deploy), the password cannot be decrypted (`SECRET_KEY_BASE` was
  rotated, see `docs/secrets-rotation.md`), or the host now resolves somewhere
  it may not. All of these **hold the mail** (`{:error, reason}`, which the
  worker raises as a retryable failure). They never fall back to the operator's
  relay.

  Falling back looks safe, and it isn't. The site set a relay so its mail would
  go through its provider, under its domain. Mail sent through the operator's
  relay instead goes out under an address the site never authorised, through a
  provider it may have left on purpose, with its subscriber list attached.
  Holding costs almost nothing: delivery is an Oban job with a ~16-hour
  greylist-aware retry schedule, so a blip delays the mail by a minute, and a
  lost password gives the admin most of a day to re-enter it before anything is
  discarded.

  ## SSRF

  The host is checked when it is saved (`Validations.RelayHost`) and again
  here, on every connection, because DNS can change in between. It is resolved
  once and connected to by address (`KilnCMS.Webhooks.SafeUrl.resolve_host_pinned/1`),
  with SNI and certificate verification pointed back at the name. gen_smtp's
  MX lookup is off (`no_mx_lookups: true`). Left on, it would resolve the
  name's MX records itself, after the check and outside the pin.

  `allow_private_hosts: true` (`config :kiln_cms, KilnCMS.Mail.SiteRelay`)
  lifts the address check for development, where the relay is a Mailpit on
  localhost. Don't set it on a deployment whose site admins you don't trust
  with your network. A self-hosted operator's own internal relay belongs in
  `SMTP_HOST`, which is not checked.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Webhooks.SafeUrl

  @type error ::
          :unavailable | :credentials_unreadable | {:host_refused, String.t()}

  @type route ::
          {:operator, Swoosh.Email.t()}
          | {:site, Swoosh.Email.t(), keyword()}
          | {:error, error()}

  @doc """
  Route `email` for the site `org_id`: `{:operator, email}` for the operator's
  relay (unchanged), `{:site, email, config}` for the site's own relay (with the
  From address, and the Message-ID's domain, moved onto the site's sending
  address), or `{:error, reason}` when the site's relay is set but cannot be
  used — see the moduledoc for why that holds the mail.
  """
  @spec route(Swoosh.Email.t(), Ash.UUID.t() | nil) :: route()
  def route(%Swoosh.Email{} = email, nil), do: {:operator, email}

  def route(%Swoosh.Email{} = email, org_id) when is_binary(org_id) do
    case resolve(org_id) do
      :operator ->
        {:operator, email}

      {:site, config, from} ->
        {:site, rehome(email, from), config}

      {:error, reason} = error ->
        Logger.warning(
          "Holding mail for site #{org_id}: its SMTP relay is set but #{describe_error(reason)}"
        )

        error
    end
  end

  @doc """
  The site's relay as a Swoosh SMTP config plus its From address,
  `:operator` when the site has none switched on, or `{:error, reason}`.
  """
  @spec resolve(Ash.UUID.t()) ::
          :operator | {:site, keyword(), {String.t(), String.t()}} | {:error, error()}
  def resolve(org_id) when is_binary(org_id) do
    case read(org_id) do
      {:ok, nil} -> :operator
      {:ok, %{enabled: false}} -> :operator
      {:ok, row} -> build(row, org_id)
      :error -> {:error, :unavailable}
    end
  end

  @doc """
  Whether the stored password decrypts — for the settings page, which has to say
  when it needs re-entering (the row itself still looks fine).
  """
  @spec password_readable?(CMS.SiteMailRelay.t()) :: boolean()
  def password_readable?(%{password_encrypted: nil}), do: true

  def password_readable?(%{password_encrypted: encrypted}),
    do: match?({:ok, _}, Vault.decrypt(encrypted))

  @doc "A sentence fragment for an `error()`, for logs and the settings page."
  @spec describe_error(error()) :: String.t()
  def describe_error(:unavailable), do: "its settings could not be read"

  def describe_error(:credentials_unreadable),
    do:
      "its password could not be decrypted (was SECRET_KEY_BASE rotated?) and must be re-entered"

  def describe_error({:host_refused, message}), do: "its host was refused: #{message}"

  @doc false
  # See the moduledoc's SSRF section.
  @spec allow_private_hosts?() :: boolean()
  def allow_private_hosts?, do: config()[:allow_private_hosts] == true

  # The row, `nil` when the site has none, or `:error` when it could not be read.
  #
  # `authorize?: false` — a system read, and the bypass is safe here: the
  # delivery job has no actor to authorize (the resource's read policy is
  # org-admin, and a mail job is nobody), the read is tenant-scoped to the one
  # site the mail is being sent for, and the row never leaves this module
  # except as that site's own connection config. Same shape as the other
  # per-site resolvers (`KilnCMS.Branding`, `KilnCMS.Feeds`).
  defp read(org_id) do
    case CMS.list_site_mail_relay(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} when is_exception(error) -> unreadable(org_id, Exception.message(error))
      {:error, error} -> unreadable(org_id, inspect(error))
    end
  rescue
    error -> unreadable(org_id, Exception.message(error))
  end

  defp unreadable(org_id, detail) do
    Logger.error("SMTP relay settings for site #{org_id} could not be read: #{detail}")
    :error
  end

  defp build(row, org_id) do
    with {:ok, credentials} <- credentials(row),
         {:ok, relay} <- relay(row.host) do
      config =
        [
          adapter: config()[:adapter] || Swoosh.Adapters.SMTP,
          relay: relay,
          port: row.port,
          # The pin above is the SSRF check; an MX lookup would re-resolve the
          # name outside it.
          no_mx_lookups: true
        ]
        |> Keyword.merge(credentials)
        |> Keyword.merge(security(row.security, row.host))

      {:site, config, {from_name(row, org_id), row.from_email}}
    end
  end

  # Swoosh refuses a `nil` username or password, so with no username neither key
  # is sent at all — and, because the config is not merged over the operator's,
  # nothing fills them in.
  defp credentials(%{username: username} = row) when is_binary(username) and username != "" do
    with encrypted when is_binary(encrypted) <- row.password_encrypted,
         {:ok, password} <- Vault.decrypt(encrypted) do
      {:ok, [auth: :always, username: username, password: password]}
    else
      _unreadable -> {:error, :credentials_unreadable}
    end
  end

  defp credentials(_row), do: {:ok, [auth: :never]}

  defp relay(host) do
    if allow_private_hosts?() do
      {:ok, host}
    else
      case SafeUrl.resolve_host_pinned(host) do
        {:ok, nil} -> {:ok, host}
        {:ok, address} -> {:ok, address |> :inet.ntoa() |> to_string()}
        {:error, message} -> {:error, {:host_refused, message}}
      end
    end
  end

  # STARTTLS upgrades through `tls_options`; implicit TLS connects through
  # `sockopts` (gen_smtp hands those to `ssl:connect/4`). Both carry the same
  # verification, so neither mode is the weaker one.
  defp security(:starttls, host),
    do: [ssl: false, tls: :always, tls_options: verify(host), sockopts: []]

  defp security(:tls, host),
    do: [ssl: true, tls: :never, tls_options: verify(host), sockopts: verify(host)]

  # The connection goes to an address, so the certificate is checked against the
  # name the admin typed: SNI names it, and `customize_hostname_check` matches
  # it the way a browser would (wildcards included). An IP the admin typed gets
  # no SNI (it is not a legal SNI value) and is checked as an IP.
  defp verify(host) do
    [
      verify: :verify_peer,
      cacertfile: CAStore.file_path(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ] ++ sni(host)
  end

  defp sni(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} -> []
      _name -> [server_name_indication: String.to_charlist(host)]
    end
  end

  defp from_name(%{from_name: name}, _org_id) when is_binary(name) and name != "", do: name
  defp from_name(_row, org_id), do: KilnCMS.Branding.for_org(org_id).site_name

  # The From moves to the site's address. The Message-ID was stamped with the
  # old From's domain (at enqueue, so retries share it), and one that doesn't
  # match the From is a spam signal. Only the domain moves, so the ID stays
  # stable across retries.
  defp rehome(%Swoosh.Email{from: old_from} = email, {_name, address} = from) do
    email = %{email | from: from}

    with {_old_name, old_address} <- old_from,
         id when is_binary(id) <- email.headers["Message-ID"] do
      old_suffix = "@" <> KilnCMS.Mail.domain_of(old_address) <> ">"
      new_suffix = "@" <> KilnCMS.Mail.domain_of(address) <> ">"

      if String.ends_with?(id, old_suffix) do
        new_id = String.replace_suffix(id, old_suffix, new_suffix)
        %{email | headers: Map.put(email.headers, "Message-ID", new_id)}
      else
        email
      end
    else
      _no_id -> email
    end
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
