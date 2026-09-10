defmodule KilnCMSWeb.PublicThemeTest do
  @moduledoc """
  The public theme layer (#1318), as it reaches the browser: the
  `data-public-theme` attribute, the branding-selected header/footer menus, and
  the code-injection custom stylesheet.

  `async: false` — branding, menu trees and code injection all live in the
  shared Cachex, and these tests bust them.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  setup do
    org = seed_org()

    on_exit(fn ->
      KilnCMS.Cache.bust_branding(org.id)
      KilnCMS.Cache.bust_code_injection(org.id)
      KilnCMS.Cache.bump_menus_generation(org.id)
    end)

    %{org: org, admin: platform_admin()}
  end

  describe "theme preset" do
    test "an unconfigured site renders the standard theme", %{conn: conn} do
      html = conn |> get(~p"/blog") |> html_response(200)

      assert html =~ ~s(data-public-theme="standard")
    end

    test "a selected preset lands on the shell attribute", ctx do
      brand(ctx, %{theme: :editorial})

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)

      assert html =~ ~s(data-public-theme="editorial")
    end

    test "a preset outside the closed list is refused at save", ctx do
      assert_raise Ash.Error.Invalid, fn ->
        CMS.save_site_branding!(%{theme: :neon}, actor: ctx.admin, tenant: ctx.org)
      end
    end
  end

  describe "header menu slot" do
    test "top-level items replace the stock links", ctx do
      menu(ctx, "main", [{"Pricing", "/pricing"}, {"About", "/about"}])
      brand(ctx, %{header_menu_key: "main"})

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)

      assert html =~ "Pricing"
      assert html =~ ~s(href="/pricing")
      refute html =~ ~s(href="/search")
    end

    test "a key that resolves to no menu falls back to the stock links", ctx do
      brand(ctx, %{header_menu_key: "renamed-away"})

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)

      assert html =~ ~s(href="/search")
    end

    test "a menu edit is visible without waiting out the TTL", ctx do
      %{items: [item]} = menu(ctx, "main", [{"Pricing", "/pricing"}])
      brand(ctx, %{header_menu_key: "main"})

      assert ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200) =~ "Pricing"

      CMS.update_menu_item!(item, %{label: "Plans"}, actor: ctx.admin, tenant: ctx.org)

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)
      assert html =~ "Plans"
      refute html =~ "Pricing"
    end
  end

  describe "footer menu slot" do
    test "renders sections with their child links above the attribution", ctx do
      %{menu: menu, items: [company]} = menu(ctx, "footer", [{"Company", nil}])

      CMS.create_menu_item!(
        %{
          menu_id: menu.id,
          parent_id: company.id,
          label: "Careers",
          link_type: :url,
          url: "/careers",
          position: 0
        },
        actor: ctx.admin,
        tenant: ctx.org
      )

      brand(ctx, %{footer_menu_key: "footer"})

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)

      assert html =~ "Company"
      assert html =~ ~s(href="/careers")
      assert html =~ ~s(aria-label="Footer")
    end

    test "no footer nav renders when the slot is unconfigured", %{conn: conn} do
      refute conn |> get(~p"/blog") |> html_response(200) =~ ~s(aria-label="Footer")
    end
  end

  describe "custom CSS (code injection)" do
    test "is served inside a <style> element on delivery pages", ctx do
      inject(ctx, %{custom_css: ".public-shell { --public-measure: 90rem; }"})

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)

      assert html =~ "data-custom-css"
      assert html =~ "--public-measure: 90rem"
    end

    test "a value containing </style is refused at save", ctx do
      assert_raise Ash.Error.Invalid, ~r/style/, fn ->
        inject(ctx, %{custom_css: "body{} </StYlE><script>1</script>"})
      end
    end

    test "a stored breakout that predates the validation is dropped at read", ctx do
      # Seeding skips validations (not casts), which is exactly the historical
      # row this guards against.
      Ash.Seed.seed!(CMS.SiteCodeInjection, %{
        org_id: ctx.org.id,
        custom_css: "body{}</style><script>1</script>"
      })

      KilnCMS.Cache.bust_code_injection(ctx.org.id)

      html = ctx.conn |> org_conn(ctx.org) |> get(~p"/blog") |> html_response(200)

      refute html =~ "data-custom-css"
      refute html =~ "</style><script>"
    end
  end

  defp brand(%{org: org, admin: admin}, attrs) do
    CMS.save_site_branding!(attrs, actor: admin, tenant: org)
    KilnCMS.Cache.bust_branding(org.id)
  end

  defp inject(%{org: org, admin: admin}, attrs) do
    row = CMS.save_site_code_injection!(attrs, actor: admin, tenant: org)
    KilnCMS.Cache.bust_code_injection(org.id)
    row
  end

  # A menu named `key` in the default locale with one top-level `:url` item per
  # `{label, url}` (a nil url is a `:none` heading).
  defp menu(%{org: org, admin: admin}, key, entries) do
    menu =
      CMS.create_menu!(%{key: key, name: key, locale: KilnCMS.I18n.default_locale()},
        actor: admin,
        tenant: org
      )

    items =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {{label, url}, position} ->
        attrs =
          if url,
            do: %{link_type: :url, url: url},
            else: %{link_type: :none}

        CMS.create_menu_item!(
          Map.merge(%{menu_id: menu.id, label: label, position: position}, attrs),
          actor: admin,
          tenant: org
        )
      end)

    %{menu: menu, items: items}
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Theme Site",
      slug: "theme-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp platform_admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "theme-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end
end
