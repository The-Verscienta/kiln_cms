defmodule KilnCMSWeb.Plugs.ChallengeCsp do
  @moduledoc """
  Lets the sign-in and registration pages load the human-verification widget
  (#2249).

  The widget is a script and an iframe from the provider's origin
  (`https://challenges.cloudflare.com` for Turnstile), which the auth pages'
  policy does not otherwise allow. This adds the provider's
  `c:Kiln.Challenge.Provider.csp_sources/0` to `script-src`, `frame-src` and
  `connect-src` of the policy `put_browser_csp` already set on `:browser_auth`.

  Only while a challenge can actually be shown — a provider configured and
  usable, and sign-in or registration not `:off`. Otherwise the header is left
  byte-for-byte as it was: a deployment that has not configured a provider, or
  has thrown `KILN_CHALLENGE_DISABLED`, trusts no third-party origin it does
  not use.

  The whole `:browser_auth` pipeline rather than `/sign-in` and `/register`
  alone, because those pages and `/reset` are one LiveView patched between: a
  visitor who lands on `/reset` and follows the link to sign in is still under
  the policy the first page was served with. And never the console or the
  public site: the challenge is drawn nowhere else.

  Directives the policy does not name are left alone rather than added — this
  plug widens a policy, it does not write one (the same rule as
  `KilnCMSWeb.Plugs.SiteStorageCsp`).

  ## Public forms

  A public form that asks for a challenge is drawn on the site's own pages,
  not on `:browser_auth`, so it is not this plug's pipeline that widens for it.
  `widen_for_forms/2` is called by the controller that renders such a form —
  a delivered page, `/forms/:slug`, a refused re-render — and only for a
  response that actually draws one. Every other response keeps its policy
  byte-for-byte. The embed iframe writes its own policy
  (`KilnCMSWeb.Embed.content_security_policy/2`).
  """
  @behaviour Plug

  alias KilnCMS.Challenge

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    sources = Challenge.csp_sources(Challenge.config())

    case Plug.Conn.get_resp_header(conn, "content-security-policy") do
      [policy | _] when map_size(sources) > 0 ->
        widened = widen_policy(policy, sources)

        if widened == policy,
          do: conn,
          else: Plug.Conn.put_resp_header(conn, "content-security-policy", widened)

      _none ->
        conn
    end
  end

  @doc """
  Widens `conn`'s policy with the provider's origins for a response that
  draws a public form's widget (#2249). A no-op when no form can ask for one
  (`KilnCMS.Challenge.forms_available?/1`) or when the response carries no
  policy. Idempotent: an origin a directive already lists is not added again.
  """
  @spec widen_for_forms(Plug.Conn.t(), Challenge.Config.t()) :: Plug.Conn.t()
  def widen_for_forms(conn, %Challenge.Config{} = config) do
    sources = Challenge.csp_sources(config, :forms)

    case Plug.Conn.get_resp_header(conn, "content-security-policy") do
      [policy | _] ->
        widened = widen_policy(policy, sources)

        if widened == policy,
          do: conn,
          else: Plug.Conn.put_resp_header(conn, "content-security-policy", widened)

      [] ->
        conn
    end
  end

  @doc false
  # Public for the test: the header is the whole of what this plug does.
  @spec widen_policy(String.t(), Kiln.Challenge.Provider.csp_sources()) :: String.t()
  def widen_policy(policy, sources) do
    additions = %{
      "script-src" => Map.get(sources, :script_src, []),
      "frame-src" => Map.get(sources, :frame_src, []),
      "connect-src" => Map.get(sources, :connect_src, [])
    }

    if Enum.all?(additions, fn {_directive, origins} -> origins == [] end) do
      policy
    else
      policy
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("; ", &widen_directive(&1, additions))
    end
  end

  defp widen_directive(directive, additions) do
    [name | present] = String.split(directive, " ", trim: true)

    case Map.get(additions, name, []) -- present do
      [] -> directive
      origins -> Enum.join([directive | origins], " ")
    end
  end
end
