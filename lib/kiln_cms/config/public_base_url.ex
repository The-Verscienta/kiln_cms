defmodule KilnCMS.Config.PublicBaseUrl do
  @moduledoc """
  The deployment's public base URL — `config :kiln_cms, :public_base_url` —
  as a production release resolves it (#1833).

  Every absolute public URL Kiln builds starts here, through
  `KilnCMSWeb.Tenant.base_url/1`: the sitemap, RSS/Atom feeds, canonical tags
  and JSON-LD, `llms.txt`, embed snippets, preview links, newsletter
  confirmation emails, site SSO callbacks, federation, static export and the
  provenance claim's origin. The default org uses it as-is; every other org
  keeps its scheme and port and swaps in `<slug>.<base host>`.

  Until #1833 nothing set it at runtime, so a release kept `config/config.exs`'s
  development value, `http://localhost:4000` — and a newsletter subscriber was
  mailed a confirmation link to `localhost`.

  ## Where the value comes from

    1. `PUBLIC_BASE_URL`, when it is set and not blank — for a public site
       served from a different origin than the endpoint's own.
    2. Otherwise `https://<PHX_HOST>` (`KilnCMS.Config.Host.canonical/0`), which
       is exactly what the endpoint's own `url:` config says: production
       always generates `https` URLs on port 443 (TLS is terminated in front of
       the release), so the two agree by construction.

  Either way the result is validated: an absolute `http`/`https` URL with a
  host and nothing after it — no path, query, fragment or credentials. A
  trailing `/` is dropped, the scheme and host are downcased, and a port is
  kept only when it is not the scheme's default. Anything else raises at boot,
  naming the variable: every URL above is built by appending a path to this
  value, so a stray `/blog` or `?x=1` would be silently wrong in all of them.

  Development and test keep `config/config.exs`'s `http://localhost:4000`;
  this module is only called from the production runtime config.
  """

  alias KilnCMS.Config.Host

  @var "PUBLIC_BASE_URL"

  @doc """
  The public base URL for this boot: `PUBLIC_BASE_URL` if set, else
  `https://<PHX_HOST>`, normalized by `normalize!/2`.

  Raises if the value it lands on is not a usable base URL.
  """
  @spec from_env() :: String.t()
  def from_env do
    # Blank counts as unset — the convention every other variable follows.
    raw = System.get_env("PUBLIC_BASE_URL", "")

    if String.trim(raw) == "", do: derived(), else: normalize!(raw, @var)
  end

  defp derived, do: normalize!("https://" <> Host.canonical(), "PHX_HOST")

  @doc """
  Normalizes `raw` into `scheme://host[:port]`, or raises naming `source` (the
  variable the operator would fix).

      iex> KilnCMS.Config.PublicBaseUrl.normalize!("https://CMS.Example.com/", "PUBLIC_BASE_URL")
      "https://cms.example.com"

      iex> KilnCMS.Config.PublicBaseUrl.normalize!("https://cms.example.com:443", "PUBLIC_BASE_URL")
      "https://cms.example.com"

      iex> KilnCMS.Config.PublicBaseUrl.normalize!("http://cms.example.com:8080", "PUBLIC_BASE_URL")
      "http://cms.example.com:8080"
  """
  @spec normalize!(String.t(), String.t()) :: String.t()
  def normalize!(raw, source) when is_binary(raw) and is_binary(source) do
    uri = raw |> String.trim() |> URI.parse()
    scheme = uri.scheme && String.downcase(uri.scheme)

    cond do
      scheme not in ["http", "https"] ->
        invalid!(raw, source, "it must start with https:// (or http://)")

      uri.host in [nil, ""] ->
        invalid!(raw, source, "it has no host name")

      uri.userinfo != nil ->
        invalid!(raw, source, "it must not carry a user name or password")

      uri.path not in [nil, "", "/"] ->
        invalid!(raw, source, "it must not have a path (#{inspect(uri.path)})")

      uri.query != nil or uri.fragment != nil ->
        invalid!(raw, source, "it must not have a query string or fragment")

      true ->
        URI.to_string(%URI{
          scheme: scheme,
          host: uri.host |> String.downcase() |> String.trim_trailing("."),
          port: uri.port
        })
    end
  end

  defp invalid!(raw, source, why) do
    raise """
    #{source} does not give a usable public base URL (#{inspect(raw)}): #{why}.

    Kiln builds every absolute public URL — sitemap, feeds, canonical links,
    newsletter confirmation emails, preview links — by appending a path to this
    value, so it must be an origin and nothing else, e.g. https://cms.example.com.
    Set PHX_HOST to the bare public host name, or PUBLIC_BASE_URL to the full
    origin when the public site is served from somewhere else.
    """
  end

  @doc """
  A warning for a production boot whose public base URL points at this
  machine, or `nil`.

  `localhost` is a legitimate value for a production build run on a laptop, so
  this warns rather than refusing to boot. On a real deployment it means every
  link Kiln sends out — in a feed, a sitemap, an email — leads nowhere.
  """
  @spec boot_warning(atom(), String.t() | nil) :: String.t() | nil
  def boot_warning(
        env \\ Application.get_env(:kiln_cms, :compile_env),
        url \\ Application.get_env(:kiln_cms, :public_base_url)
      )

  def boot_warning(:prod, url) when is_binary(url) do
    if local?(url) do
      "The public base URL is #{url}, which points at this machine. Every absolute " <>
        "link Kiln generates — sitemap, feeds, canonical tags, newsletter " <>
        "confirmation emails, preview links — will use it. Set PHX_HOST to the " <>
        "public host name (or PUBLIC_BASE_URL to the full public origin)."
    end
  end

  def boot_warning(_env, _url), do: nil

  @doc """
  Whether `url`'s host is this machine: `localhost`, a `*.localhost` name, or a
  loopback address.
  """
  @spec local?(String.t()) :: boolean()
  def local?(url) when is_binary(url) do
    case URI.parse(url).host do
      nil ->
        false

      host ->
        host = String.downcase(host)

        host == "localhost" or String.ends_with?(host, ".localhost") or
          loopback_ip?(host)
    end
  end

  defp loopback_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end
end
