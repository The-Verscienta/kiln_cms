defmodule KilnCMS.Accounts.SiteSso.DomainCheck do
  @moduledoc """
  The DNS proof behind `KilnCMS.CMS.SiteSsoDomain` (#1561): a TXT record at
  `_kiln-sso.<domain>` whose value is `kiln-sso-verification=<token>`.

  A name of its own, rather than a record at the domain's apex, so it cannot
  collide with SPF or any other apex TXT record, and so it is obvious in a zone
  file what it is for.

  Lookups go through the same seam as the mail DNS checks
  (`config :kiln_cms, KilnCMS.Mail.DnsCheck, dns: ...`, default
  the `:inet_res` resolver, bounded at 2s × 1 retry), so the test suite
  never touches the network.
  """

  @prefix "_kiln-sso."
  @value_prefix "kiln-sso-verification="

  # A DNS name: labels of letters, digits and hyphens, at least two of them.
  @domain ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/

  @doc "Where the TXT record goes."
  @spec record_name(String.t()) :: String.t()
  def record_name(domain), do: @prefix <> domain

  @doc "What the TXT record must say."
  @spec record_value(String.t()) :: String.t()
  def record_value(token), do: @value_prefix <> token

  @doc "A fresh, unguessable verification token."
  @spec new_token() :: String.t()
  def new_token do
    20 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end

  @doc "A domain as the sign-in path compares it: trimmed, lower-case, no trailing dot."
  @spec normalize(String.t()) :: String.t()
  def normalize(domain) when is_binary(domain) do
    domain |> String.trim() |> String.downcase() |> String.trim_trailing(".")
  end

  @doc "Whether a normalised string is a multi-label DNS name."
  @spec valid_domain?(String.t()) :: boolean()
  def valid_domain?(domain) when is_binary(domain), do: Regex.match?(@domain, domain)
  def valid_domain?(_domain), do: false

  @doc """
  The domain half of an email address, normalised, or `nil` when it has none.
  Splits on the **last** `@`, as a mail system routes it.
  """
  @spec email_domain(term()) :: String.t() | nil
  def email_domain(email) when is_binary(email) do
    case email |> String.trim() |> String.split("@") do
      [_single] -> nil
      parts -> parts |> List.last() |> normalize() |> nil_if_blank()
    end
  end

  def email_domain(_email), do: nil

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(domain), do: domain

  @doc """
  Whether `domain`'s record is published with `token`, right now. A lookup
  failure is `false`: an unanswerable question is not a yes.
  """
  @spec published?(String.t(), String.t()) :: boolean()
  def published?(domain, token)
      when is_binary(domain) and is_binary(token) and token != "" do
    expected = record_value(token)

    domain
    |> record_name()
    |> dns().txt()
    |> Enum.any?(&(String.trim(&1) == expected))
  rescue
    _lookup_failure -> false
  end

  def published?(_domain, _token), do: false

  defp dns do
    :kiln_cms
    |> Application.get_env(KilnCMS.Mail.DnsCheck, [])
    |> Keyword.get(:dns, KilnCMS.Mail.DnsCheck.InetDNS)
  end
end
