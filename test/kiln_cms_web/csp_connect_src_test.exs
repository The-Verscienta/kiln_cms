defmodule KilnCMSWeb.CspConnectSrcTest do
  @moduledoc """
  The served `connect-src` (#1615; threat-model residual 12).

  It used to be `'self' ws: wss:`, which let any script that got past
  `script-src` open a websocket to any host. Every socket Kiln's own pages open
  is same-origin, and `'self'` covers `ws:`/`wss:` on the page's own host
  (`e2e/tests/csp.spec.js` proves that in a real browser), so the directive is
  now `'self'` alone. These assert it EXACTLY, so a source creeping back in
  fails here rather than in a review.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp directives(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")

    policy
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.group_by(&(&1 |> String.split(" ", parts: 2) |> hd()))
  end

  defp connect_src(conn), do: directives(conn)["connect-src"]

  setup do
    on_exit(fn -> KilnCMS.Cache.bust_code_injection(org_id()) end)
    :ok
  end

  test "a console LiveView page serves connect-src 'self' and nothing else", %{conn: conn} do
    assert connect_src(get(conn, ~p"/sign-in")) == ["connect-src 'self'"]
  end

  test "a public delivery page serves connect-src 'self' and nothing else", %{conn: conn} do
    page =
      Ash.Seed.seed!(Page, %{
        title: "CSP",
        slug: "csp-#{System.unique_integer([:positive])}",
        state: :published
      })

    assert connect_src(get(conn, ~p"/#{page.slug}")) == ["connect-src 'self'"]
  end

  test "no scheme-only websocket source survives anywhere in the policy", %{conn: conn} do
    policy = conn |> get(~p"/sign-in") |> get_resp_header("content-security-policy") |> hd()

    refute policy =~ ~r/(^|\s)wss?:(\s|;|$)/
  end

  # The one way a site widens it: its own code injection, per site. A vendor
  # websocket has to be named as a `wss://` origin, because an `https://` source
  # does not admit a `wss://` URL.
  test "a site's code injection adds its wss:// origin to connect-src", %{conn: conn} do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "csp-connect-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.save_site_code_injection!(
      %{"connect_src" => ["https://widget.example", "wss://relay.widget.example"]},
      actor: admin,
      tenant: org_id()
    )

    page =
      Ash.Seed.seed!(Page, %{
        title: "CSP",
        slug: "csp-#{System.unique_integer([:positive])}",
        state: :published
      })

    assert connect_src(get(conn, ~p"/#{page.slug}")) == [
             "connect-src 'self' https://widget.example wss://relay.widget.example"
           ]
  end
end
