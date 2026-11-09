defmodule KilnCMSWeb.Plugs.ChallengeCsp do
  @moduledoc """
  Lets the sign-in and registration pages load the human-verification widget
  (#2249).

  The widget is a script and an iframe from the provider's origin
  (`https://challenges.cloudflare.com` for Turnstile), which the auth pages'
  policy does not otherwise allow. This adds the provider's
  `c:KilnCMS.Challenge.Provider.csp_sources/0` to `script-src`, `frame-src` and
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

  @doc false
  # Public for the test: the header is the whole of what this plug does.
  @spec widen_policy(String.t(), KilnCMS.Challenge.Provider.csp_sources()) :: String.t()
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
    name = directive |> String.split(" ", parts: 2) |> hd()

    case Map.get(additions, name, []) do
      [] -> directive
      origins -> Enum.join([directive | origins], " ")
    end
  end
end
