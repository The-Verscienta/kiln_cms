defmodule KilnCMS.Mailer.DirectMX do
  @moduledoc """
  Swoosh adapter that delivers mail straight to each recipient domain's MX
  hosts ("direct delivery", `MAIL_MODE=direct`) instead of relaying through a
  smarthost — the built-in-MTA mode of `docs/direct-email-delivery-plan.md`.

  For every recipient domain the adapter hands the message to
  `Swoosh.Adapters.SMTP` with the domain itself as the relay: gen_smtp
  resolves the domain's MX records (`no_mx_lookups: false`, falling back to
  the A record per RFC 5321) and speaks SMTP on port 25. No authentication,
  IPv4 only (IPv6 sending carries stricter reputation requirements), and
  opportunistic STARTTLS: encryption when the MX offers it, without
  certificate verification — MX certificates are routinely self-signed and
  real MTAs treat STARTTLS as confidentiality, not authentication.

  Messages are DKIM-signed when `KilnCMS.Mail.dkim_config/0` returns signing
  options; `nil` (no key configured yet) sends unsigned.

  In the normal pipeline each Oban delivery job carries exactly one recipient
  (`KilnCMS.Mail.enqueue!/1`), so the per-domain fan-out here degenerates to a
  single send; it exists so the adapter is also correct for direct
  `Mailer.deliver/2` calls. On a multi-domain send a failing domain fails the
  whole delivery (Swoosh's contract has no partial success), so a retrying
  caller could re-send to a domain that already accepted — one more reason
  the pipeline enqueues per recipient.

  Config (all optional):

    * `:hostname` — HELO/EHLO name (`MAIL_HELO_HOST`, defaulting to
      `PHX_HOST`); deliverability requires it to match the sending IP's PTR.
    * `:dkim` — signing options, overriding `KilnCMS.Mail.dkim_config/0`.
    * `:relay_override`, `:port`, `:tls`, `:no_mx_lookups`, `:smtp_adapter` —
      test/tooling seams to aim the adapter at a local sink instead of real
      MX hosts.
  """
  use Swoosh.Adapter

  alias Swoosh.Email

  @impl true
  def deliver(%Email{} = email, config) do
    smtp_adapter = Keyword.get(config, :smtp_adapter, Swoosh.Adapters.SMTP)
    dkim = Keyword.get(config, :dkim) || KilnCMS.Mail.dkim_config()

    email
    |> domains()
    |> Enum.reduce_while([], fn domain, receipts ->
      case smtp_adapter.deliver(for_domain(email, domain), smtp_config(domain, dkim, config)) do
        {:ok, receipt} -> {:cont, [receipt | receipts]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      receipts -> {:ok, %{receipts: Enum.reverse(receipts)}}
    end
  end

  defp domains(email) do
    [email.to, email.cc, email.bcc]
    |> Enum.concat()
    |> Enum.map(fn {_name, address} -> domain_of(address) end)
    |> Enum.uniq()
  end

  # Envelope recipients not in this domain are dropped from their original
  # field (rather than collapsed into :to) so the rendered To/Cc headers stay
  # truthful on multi-recipient sends.
  defp for_domain(email, domain) do
    %{
      email
      | to: filter(email.to, domain),
        cc: filter(email.cc, domain),
        bcc: filter(email.bcc, domain)
    }
  end

  defp filter(recipients, domain),
    do: Enum.filter(recipients, fn {_name, address} -> domain_of(address) == domain end)

  defp domain_of(address), do: KilnCMS.Mail.domain_of(address)

  # Unrecognised config keys pass through to the SMTP adapter (matching
  # Swoosh convention); only this adapter's own seam keys are stripped.
  defp smtp_config(domain, dkim, config) do
    computed =
      [
        relay: Keyword.get(config, :relay_override, domain),
        port: Keyword.get(config, :port, 25),
        no_mx_lookups: Keyword.get(config, :no_mx_lookups, false),
        auth: :never,
        tls: Keyword.get(config, :tls, :if_available),
        # verify_none is deliberate (see @moduledoc): opportunistic STARTTLS
        # encrypts the hop but cannot authenticate arbitrary MX hosts.
        tls_options: [verify: :verify_none, versions: [:"tlsv1.2", :"tlsv1.3"]],
        sockopts: [:inet]
      ]
      |> maybe_put(:dkim, dkim)

    config
    |> Keyword.drop([:smtp_adapter, :relay_override, :dkim, :adapter])
    |> Keyword.merge(computed)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]
end
