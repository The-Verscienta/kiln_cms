defmodule KilnCMSWeb.CodeInjectionDeliveryTest do
  @moduledoc """
  Where a site's injected snippet renders, and under what policy (#490).

  This is the half of the feature that cannot be checked by reading the
  resource: the snippet is stored XSS by design, so what bounds it is the
  pipeline it renders in and the CSP that ships with it.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "inject-web-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    Ash.Seed.seed!(Page, %{title: "Injected", slug: "inject-#{uniq()}", state: :published})
  end

  defp inject!(attrs) do
    CMS.save_site_code_injection!(attrs, actor: admin(), tenant: org_id())
  end

  setup do
    on_exit(fn -> KilnCMS.Cache.bust_code_injection(org_id()) end)
    :ok
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  describe "delivery" do
    test "renders the head and footer snippets verbatim", %{conn: conn} do
      page = published_page()

      inject!(%{
        "head_html" => ~s(<meta name="verify" content="abc123" />),
        "footer_html" => "<script>widget()</script>"
      })

      html = conn |> get(~p"/#{page.slug}") |> html_response(200)

      assert html =~ ~s(<meta name="verify" content="abc123" />)
      assert html =~ "<script>widget()</script>"
    end

    test "adds the site's origins and script hashes to the CSP", %{conn: conn} do
      page = published_page()

      inject!(%{
        "head_html" => "<script>track()</script>",
        "script_src" => ["https://plausible.io"],
        "connect_src" => ["https://plausible.io"],
        "img_src" => ["https://pixel.example"]
      })

      conn = get(conn, ~p"/#{page.slug}")
      policy = csp(conn)
      hash = Base.encode64(:crypto.hash(:sha256, "track()"))

      assert policy =~ "https://plausible.io"
      assert policy =~ "'sha256-#{hash}'"
      assert policy =~ "https://pixel.example"

      # Widened in place, never a second header — browsers INTERSECT multiple
      # policies, so an appended one would leave the snippet blocked.
      assert length(get_resp_header(conn, "content-security-policy")) == 1

      # And the additions land in the right directives.
      assert policy =~ ~r/script-src[^;]*https:\/\/plausible\.io/
      assert policy =~ ~r/img-src[^;]*https:\/\/pixel\.example/
      refute policy =~ ~r/img-src[^;]*plausible/
    end

    test "the nonce and 'self' survive the rewrite", %{conn: conn} do
      page = published_page()
      inject!(%{"script_src" => ["https://plausible.io"]})

      policy = conn |> get(~p"/#{page.slug}") |> csp()

      assert policy =~ ~r/script-src 'self' 'nonce-[^']+' https:\/\/plausible\.io/
      assert policy =~ "object-src 'none'"
      assert policy =~ "frame-ancestors 'self'"
    end

    test "a site with no injection gets the stock policy and no markup", %{conn: conn} do
      page = published_page()

      conn = get(conn, ~p"/#{page.slug}")

      assert csp(conn) =~ "script-src 'self' 'nonce-"
      refute csp(conn) =~ "sha256-"
      refute html_response(conn, 200) =~ "widget()"
    end

    test "a disabled site renders nothing and widens nothing", %{conn: conn} do
      page = published_page()

      inject!(%{
        "head_html" => "<script>track()</script>",
        "script_src" => ["https://plausible.io"],
        "enabled" => false
      })

      conn = get(conn, ~p"/#{page.slug}")

      refute html_response(conn, 200) =~ "track()"
      refute csp(conn) =~ "plausible"
    end
  end

  describe "the console is never injected" do
    # The root layout is shared, so the ONLY thing keeping an org admin's script
    # out of an operator's authenticated console session is that the console does
    # not pipe through `:delivery`. If that ever stops being true, this fails.
    test "sign-in renders no snippet and gets no widened policy", %{conn: conn} do
      inject!(%{
        "head_html" => ~s(<meta name="verify" content="abc123" />),
        "script_src" => ["https://plausible.io"]
      })

      conn = get(conn, ~p"/sign-in")
      html = html_response(conn, 200)

      refute html =~ "abc123"
      refute csp(conn) =~ "plausible"
    end
  end
end
