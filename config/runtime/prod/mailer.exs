import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# ## SSL Support
#
# To get SSL working, you will need to add the `https` key
# to your endpoint configuration:
#
#     config :kiln_cms, KilnCMSWeb.Endpoint,
#       https: [
#         ...,
#         port: 443,
#         cipher_suite: :strong,
#         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
#         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
#       ]
#
# The `cipher_suite` is set to `:strong` to support only the
# latest and more secure SSL ciphers. This means old browsers
# and clients may not be supported. You can set it to
# `:compatible` for wider support.
#
# `:keyfile` and `:certfile` expect an absolute path to the key
# and cert in disk or a relative path inside priv, for example
# "priv/ssl/server.key". For all supported SSL configuration
# options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
#
# We also recommend setting `force_ssl` in your config/prod.exs,
# ensuring no data is ever sent via http, always redirecting to https:
#
#     config :kiln_cms, KilnCMSWeb.Endpoint,
#       force_ssl: [hsts: true]
#
# Check `Plug.SSL` for all available options in `force_ssl`.

# ## Configuring the mailer
#
# config/config.exs defaults to Swoosh.Adapters.Local — a dev-only in-memory
# mailbox with no delivery, and no supervised storage process outside `mix
# phx.server`. All outbound email is queued through KilnCMS.Mail onto the
# Oban :mail queue, so with no real adapter configured in production the
# triggering requests still succeed but every delivery job fails and retries
# in Oban (visible in the oban_jobs table / logs) — no email actually leaves.
#
# Two real-delivery modes (docs/direct-email-delivery-plan.md):
#
#   * MAIL_MODE=smtp (or just setting SMTP_HOST, the pre-MAIL_MODE opt-in) —
#     relay through any SMTP server (Postmark, SES, Gmail, ...). TLS is on
#     by default (STARTTLS on 587); set SMTP_TLS=false for an unencrypted
#     relay (e.g. a local dev/test relay).
#   * MAIL_MODE=direct — no relay: deliver straight to each recipient
#     domain's MX hosts on port 25, DKIM-signed once a key is configured.
#     Requires MAIL_FROM_EMAIL (its domain is the sending domain) and
#     correct DNS (SPF/DKIM/DMARC/PTR) — see /editor/mail once Phase 5
#     lands, and mind that many cloud hosts block outbound port 25.
# Treat a blank MAIL_MODE ("" — a common `MAIL_MODE=` .env/compose artifact)
# as unset rather than an unknown mode: an empty string is truthy in Elixir,
# so without this it would fall through to the `other -> raise` clause and
# crash boot (and mask a set SMTP_HOST, since `||` wouldn't fall back).
mail_mode =
  case System.get_env("MAIL_MODE") do
    blank when blank in [nil, ""] -> System.get_env("SMTP_HOST") && "smtp"
    mode -> mode
  end

case mail_mode do
  "smtp" ->
    smtp_host =
      System.get_env("SMTP_HOST") ||
        raise "MAIL_MODE=smtp requires SMTP_HOST (the relay to send through)"

    # Explicit TLS options for STARTTLS: since OTP 26 the ssl app defaults to
    # `verify_peer` with no CA store configured, so gen_smtp's handshake to any
    # relay dies with :tls_failed unless we supply one. Verify against
    # CAStore's bundle (with SNI, required by multi-tenant relays) by default;
    # SMTP_TLS_VERIFY=false keeps the connection encrypted but skips peer
    # verification, for relays with self-signed or mismatched certificates.
    smtp_tls_options =
      if Env.flag("SMTP_TLS_VERIFY", true) do
        [
          verify: :verify_peer,
          cacertfile: CAStore.file_path(),
          server_name_indication: String.to_charlist(smtp_host),
          depth: 3
        ]
      else
        [verify: :verify_none]
      end

    config :kiln_cms, KilnCMS.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      tls: if(Env.flag("SMTP_TLS", true), do: :always, else: :never),
      tls_options: smtp_tls_options,
      auth: :always

  "direct" ->
    unless System.get_env("MAIL_FROM_EMAIL") do
      raise """
      MAIL_MODE=direct requires MAIL_FROM_EMAIL: its domain is the sending
      (and DKIM signing) domain, and async bounces are delivered to it.
      """
    end

    # `KilnCMS.Config.Host.canonical()` rather than the `host` variable this
    # read while runtime.exs was one file: the endpoint block that derived it
    # now lives in `runtime/prod/web.exs`, and a local does not cross an
    # fragment boundary. Same value, same rule, stated once.
    helo_host =
      case System.get_env("MAIL_HELO_HOST") do
        empty when empty in [nil, ""] -> KilnCMS.Config.Host.canonical()
        helo -> helo
      end

    config :kiln_cms, KilnCMS.Mailer,
      adapter: KilnCMS.Mailer.DirectMX,
      # HELO name; deliverability requires the sending IP's PTR record to
      # resolve to this host.
      hostname: helo_host

  nil ->
    :ok

  other ->
    raise "unknown MAIL_MODE #{inspect(other)} — expected \"smtp\" or \"direct\""
end

# Persist the resolved mode so the admin mail page reports it authoritatively
# instead of reverse-inferring it from the adapter module (which mislabels a
# downstream project's custom Swoosh adapter as "no real delivery").
config :kiln_cms, :mail_mode, mail_mode

if from_email = System.get_env("MAIL_FROM_EMAIL") do
  config :kiln_cms, email_from: {System.get_env("MAIL_FROM_NAME") || "KilnCMS", from_email}
end
