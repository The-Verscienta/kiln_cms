defmodule KilnCMS.BrandingTest do
  @moduledoc """
  The white-label resolve chain (#48): per-site row -> instance config -> stock
  defaults, per field.

  `async: false` — these mutate application env and the shared Cachex.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Branding
  alias KilnCMS.CMS

  setup do
    original = Application.get_env(:kiln_cms, :branding)
    Application.put_env(:kiln_cms, :branding, [])

    # Enter clean as well as leave clean — a cached branding entry outlives the
    # test that wrote it by up to the TTL. See `KilnCMSWeb.ManifestControllerTest`.
    KilnCMS.Cache.bust_branding(Accounts.default_org_id())

    on_exit(fn ->
      Application.put_env(:kiln_cms, :branding, original)
      KilnCMS.Cache.bust_branding(Accounts.default_org_id())
    end)

    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)

    %{org: org, admin: platform_admin()}
  end

  describe "fallback chain" do
    test "falls back to the stock defaults when nothing is configured", %{org: org} do
      brand = Branding.for_org(org)

      assert brand.site_name == "KilnCMS"
      assert brand.logo_url == "/images/logo-mark.png"
      assert brand.brand_color == nil
      assert brand.css == nil
      assert brand.show_attribution
    end

    test "the instance config layer overrides the stock defaults", %{org: org} do
      put_branding(site_name: "Operator CMS", logo_url: "/images/operator.svg")

      brand = Branding.for_org(org)

      assert brand.site_name == "Operator CMS"
      assert brand.logo_url == "/images/operator.svg"
    end

    test "a per-site row overrides the instance config", ctx do
      put_branding(site_name: "Operator CMS")
      save(ctx, %{site_name: "Acme Docs"})

      assert Branding.for_org(ctx.org).site_name == "Acme Docs"
    end

    test "the fallback is per field, not all-or-nothing", ctx do
      put_branding(site_name: "Operator CMS", logo_url: "/images/operator.svg")
      save(ctx, %{brand_color: "#0f62fe"})

      brand = Branding.for_org(ctx.org)

      # Only the colour was set on the row; the other two still inherit.
      assert brand.brand_color == "#0f62fe"
      assert brand.site_name == "Operator CMS"
      assert brand.logo_url == "/images/operator.svg"
    end

    test "a blank value falls through instead of blanking the header", ctx do
      put_branding(site_name: "Operator CMS")
      save(ctx, %{site_name: "   "})

      assert Branding.for_org(ctx.org).site_name == "Operator CMS"
    end

    test "honours the legacy :site_name config when :branding is unset", %{org: org} do
      original = Application.get_env(:kiln_cms, :site_name)
      Application.put_env(:kiln_cms, :site_name, "Legacy Name")
      on_exit(fn -> Application.put_env(:kiln_cms, :site_name, original) end)

      assert Branding.for_org(org).site_name == "Legacy Name"
    end

    test "accepts an org struct, a bare id, or nil, and never returns nil", %{org: org} do
      assert %Branding{} = Branding.for_org(org)
      assert %Branding{} = Branding.for_org(org.id)
      assert %Branding{} = Branding.for_org(nil)
    end

    test "a config brand colour that is not hex is ignored rather than emitted", %{org: org} do
      # The config layer is held to the same grammar as the column, so an env
      # var can't become the injection vector the database column isn't.
      put_branding(primary_color: "red; background: url(https://evil.example/x)")

      brand = Branding.for_org(org)

      assert brand.brand_color == nil
      assert brand.css == nil
    end
  end

  describe "read path" do
    test "never creates a row — an anonymous page view must not INSERT", ctx do
      Branding.for_org(ctx.org)
      Branding.for_org(ctx.org)

      assert {:ok, []} = CMS.list_site_branding(tenant: ctx.org, authorize?: false)
    end

    test "caches the resolved struct even when the site has no row", ctx do
      Branding.for_org(ctx.org)

      # `KilnCMS.Cache.fetch/3` never caches a nil, so caching the row lookup
      # would mean a DB hit on every request forever for the (common) unbranded
      # site. The cached value must be the resolved struct.
      assert {:ok, %Branding{}} =
               Cachex.get(KilnCMS.Cache.cache_name(), KilnCMS.Cache.branding_key(ctx.org.id))
    end

    test "a save is visible immediately, not after the TTL", ctx do
      assert Branding.for_org(ctx.org).site_name == "KilnCMS"

      save(ctx, %{site_name: "Acme Docs"})

      assert Branding.for_org(ctx.org).site_name == "Acme Docs"
    end

    test "busting one site's branding leaves another's cached", ctx do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      Branding.for_org(ctx.org)
      Branding.for_org(other)

      KilnCMS.Cache.bust_branding(ctx.org.id)

      assert {:ok, nil} =
               Cachex.get(KilnCMS.Cache.cache_name(), KilnCMS.Cache.branding_key(ctx.org.id))

      assert {:ok, %Branding{}} =
               Cachex.get(KilnCMS.Cache.cache_name(), KilnCMS.Cache.branding_key(other.id))
    end
  end

  describe "cross-org isolation" do
    test "one site's branding never leaks into another's", ctx do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      save(ctx, %{site_name: "Acme Docs", brand_color: "#0f62fe"})

      assert Branding.for_org(ctx.org).site_name == "Acme Docs"
      assert Branding.for_org(other).site_name == "KilnCMS"
      assert Branding.for_org(other).brand_color == nil
    end

    test "saving twice for one site upserts rather than creating a second row", ctx do
      save(ctx, %{site_name: "First"})
      save(ctx, %{site_name: "Second"})

      assert {:ok, [row]} = CMS.list_site_branding(tenant: ctx.org, authorize?: false)
      assert row.site_name == "Second"
    end
  end

  describe "css_variables/1" do
    test "emits nothing when the site is unbranded" do
      assert Branding.css_variables(nil) == nil
    end

    test "emits BOTH the :root and the [data-theme=dark] rule" do
      css = Branding.css_variables("#0f62fe")

      # This is the whole mechanism, not belt-and-braces: these declarations are
      # unlayered and so outrank app.css's `@layer base` dark block. A :root-only
      # override would flatten dark mode exactly like an inline style would.
      assert css =~ ":root{"
      assert css =~ ~s([data-theme="dark"]{)

      assert css =~ "--color-primary:"
      assert css =~ "--color-primary-content:"
      assert css =~ "--color-primary-ink:"
    end

    test "the light rule comes first, since both selectors are 0-1-0" do
      css = Branding.css_variables("#0f62fe")

      assert :binary.match(css, ":root{") < :binary.match(css, ~s([data-theme="dark"]{))
    end

    test "emits only hex literals it derived, never the input string" do
      css = Branding.css_variables("#0f62fe")

      # Nothing but hex colours between the braces — no CSS functions, no
      # user-supplied bytes.
      for declaration <-
            Regex.scan(~r/--color-primary[a-z-]*:([^;}]+)/, css, capture: :all_but_first) do
        assert hd(declaration) =~ ~r/\A#[0-9a-f]{6}\z/
      end
    end
  end

  defp save(%{org: org, admin: admin}, attrs) do
    CMS.save_site_branding!(attrs, actor: admin, tenant: org)
  end

  defp put_branding(opts), do: Application.put_env(:kiln_cms, :branding, opts)

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Branding Org",
      slug: "brand-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp platform_admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "brand-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end
end
