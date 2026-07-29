defmodule KilnCMSWeb.BrandTokensTest do
  @moduledoc """
  What actually reaches the browser (#48).

  Two of these are guarding silent, dark-mode-only failures that no amount of
  local clicking would surface:

    * the `<style>` block must carry the `[data-theme="dark"]` rule as well as
      `:root` — the declarations are unlayered, so a `:root`-only override
      outranks `app.css`'s `@layer base` dark block and flattens dark mode,
      exactly like the inline `style=` attribute this replaced;
    * the block must not be HTML-escaped — `<style>` is a raw-text element that
      does not decode character references, so an escaped `&quot;` would leave
      the dark selector permanently unmatched.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  setup do
    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    %{org: org}
  end

  describe "an unbranded site" do
    test "emits no <style> block at all", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "--color-primary:"
    end

    test "keeps the stock name, title suffix and attribution", %{conn: conn} do
      html = conn |> get(~p"/blog") |> html_response(200)

      assert html =~ "KilnCMS"
      assert html =~ "Powered by KilnCMS."
    end
  end

  describe "a branded site" do
    setup %{org: org} do
      brand(org, %{site_name: "Acme Docs", brand_color: "#0f62fe"})
      :ok
    end

    test "emits both the light and the dark rule", %{conn: conn, org: org} do
      html = org |> org_conn(conn) |> get(~p"/blog") |> html_response(200)

      assert html =~ ":root{--color-primary:"
      assert html =~ ~s([data-theme="dark"]{--color-primary:)
    end

    test "does not HTML-escape the dark selector", %{conn: conn, org: org} do
      html = org |> org_conn(conn) |> get(~p"/blog") |> html_response(200)

      refute html =~ "data-theme=&quot;dark&quot;"
    end

    test "emits the <style> block after the stylesheet link so it wins", %{conn: conn, org: org} do
      html = org |> org_conn(conn) |> get(~p"/blog") |> html_response(200)

      assert :binary.match(html, "/assets/css/app.css") <
               :binary.match(html, ":root{--color-primary:")
    end

    test "uses the brand name in the chrome and the title suffix", %{conn: conn, org: org} do
      html = org |> org_conn(conn) |> get(~p"/blog") |> html_response(200)

      assert html =~ "Acme Docs"
      assert html =~ "Powered by Acme Docs."
      refute html =~ "Powered by KilnCMS."
    end

    test "leaves the CSP header untouched — tenant data must never widen it", %{
      conn: conn,
      org: org
    } do
      branded = org |> org_conn(conn) |> get(~p"/blog")
      stock = Phoenix.ConnTest.build_conn() |> get(~p"/blog")

      # Identical apart from the per-request script nonce. In particular
      # `img-src` must NOT have grown a host from the branding row: that would
      # let an org admin write into a global, cross-tenant response header.
      assert csp(branded) == csp(stock)
      assert csp(branded) =~ "img-src 'self' data: blob:;"
    end

    defp csp(conn) do
      conn
      |> get_resp_header("content-security-policy")
      |> List.first()
      |> String.replace(~r/'nonce-[^']+'/, "'nonce-REDACTED'")
    end
  end

  describe "attribution toggle" do
    test "hides the footer line entirely when switched off", %{conn: conn, org: org} do
      brand(org, %{site_name: "Acme Docs", show_attribution: false})

      html = org |> org_conn(conn) |> get(~p"/blog") |> html_response(200)

      refute html =~ "Powered by"
    end
  end

  describe "Layouts.public rendered bare" do
    test "still renders stock branding with no current_org" do
      # PreviewLive, TokenPreviewLive and the error templates all call this
      # component with no attrs, so `current_org` must stay optional. The 404
      # template is the real bare call site.
      html = Phoenix.Template.render_to_string(KilnCMSWeb.ErrorHTML, "404", "html", [])

      assert html =~ "KilnCMS"
      assert html =~ "Powered by KilnCMS."
    end
  end

  defp brand(org, attrs) do
    CMS.save_site_branding!(attrs, actor: platform_admin(), tenant: org)
    KilnCMS.Cache.bust_branding(org.id)
  end

  defp org_conn(org, conn), do: %{conn | host: "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"}

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Tokens Site",
      slug: "tokens-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp platform_admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "tokens-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end
end
