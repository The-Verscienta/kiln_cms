defmodule KilnCMSWeb.SiteControllerTest do
  @moduledoc """
  `GET /api/site`, the site's link-preview defaults for headless clients
  (#2577): exactly three keys, each the value the site's own `<head>` carries,
  resolved for the site the request's host names and never another's.

  `async: false`: branding saves bust the shared Cachex table, and some tests
  set `:branding` / `:csp_img_src` / `:tenant_strict_host` / `KilnCMS.CDN`
  application env.
  """
  use KilnCMSWeb.ConnCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CDN.PurgeWorker
  alias KilnCMS.CMS
  alias KilnCMSWeb.Tenant

  @keys ~w(site_name social_image_url twitter_site)

  setup do
    org_id = Accounts.default_org_id()
    org = Accounts.get_organization!(org_id, authorize?: false)
    KilnCMS.Cache.bust_published()
    KilnCMS.Cache.bust_branding(org_id)
    on_exit(fn -> KilnCMS.Cache.bust_branding(org_id) end)

    for key <- [:branding, :csp_img_src, :tenant_strict_host, KilnCMS.CDN] do
      previous = Application.get_env(:kiln_cms, key)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:kiln_cms, key),
          else: Application.put_env(:kiln_cms, key, previous)
      end)
    end

    # No operator layer unless a test sets one, so "unset" means unset.
    Application.put_env(:kiln_cms, :branding, [])
    # A brand image on another host must be one the site's image policy allows.
    Application.put_env(:kiln_cms, :csp_img_src, ["cdn.test"])

    %{org: org, org_id: org_id}
  end

  defp tenant(slug, opts \\ []) do
    org = org(slug, opts)
    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    org
  end

  defp brand!(org_id, attrs) do
    # authorize?: false — test setup; the admin-only write is covered by
    # `KilnCMSWeb.BrandingLiveTest`.
    CMS.save_site_branding!(attrs, authorize?: false, tenant: org_id)
    KilnCMS.Cache.bust_branding(org_id)
  end

  defp site(conn \\ build_conn()), do: get(conn, "/api/site")

  defp site_json(conn \\ build_conn()), do: conn |> site() |> json_response(200)

  defp on_host(org), do: org_conn(build_conn(), org)

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "site-api-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp api_key do
    user(:editor).id
    |> Accounts.mint_api_key!(
      "site",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: :read},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  # The `content` of one `<meta>` tag, or nil.
  defp meta(html, key) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(meta[property="#{key}"], meta[name="#{key}"]))
    |> Enum.flat_map(&Floki.attribute(&1, "content"))
    |> List.first()
  end

  describe "the response" do
    test "is exactly the three keys, even when every other branding field is set", ctx do
      brand!(ctx.org_id, %{
        site_name: "Acme Docs",
        twitter_site: "@acme",
        social_image_url: "https://cdn.test/card.png",
        logo_url: "/uploads/acme-logo-secret.svg",
        favicon_url: "/uploads/acme-favicon-secret.ico",
        brand_color: "#1f6feb",
        theme: :editorial,
        header_menu_key: "acme-header-secret",
        footer_menu_key: "acme-footer-secret",
        show_attribution: false
      })

      conn = site()
      body = json_response(conn, 200)

      assert Enum.sort(Map.keys(body)) == @keys

      assert body == %{
               "site_name" => "Acme Docs",
               "twitter_site" => "@acme",
               "social_image_url" => "https://cdn.test/card.png"
             }

      for leaked <- ~w(acme-logo-secret acme-favicon-secret 1f6feb editorial
                       acme-header-secret acme-footer-secret attribution) do
        refute conn.resp_body =~ leaked, "the response carries #{leaked}"
      end
    end

    test "an unbranded site keeps every key: the stock name and two nulls" do
      assert site_json() == %{
               "site_name" => "KilnCMS",
               "twitter_site" => nil,
               "social_image_url" => nil
             }
    end

    test "the operator's name and image apply, and no operator handle exists", ctx do
      Application.put_env(:kiln_cms, :branding,
        site_name: "Operator Name",
        social_image_url: "/uploads/operator.png",
        twitter_site: "@operator"
      )

      KilnCMS.Cache.bust_branding(ctx.org_id)

      assert site_json() == %{
               "site_name" => "Operator Name",
               "twitter_site" => nil,
               "social_image_url" => Tenant.base_url(ctx.org) <> "/uploads/operator.png"
             }
    end

    test "a handle is normalized to @handle", ctx do
      brand!(ctx.org_id, %{twitter_site: "kilncms"})

      assert site_json()["twitter_site"] == "@kilncms"
    end

    test "a site's own save is visible on the next request", ctx do
      brand!(ctx.org_id, %{twitter_site: "@before"})
      assert site_json()["twitter_site"] == "@before"

      # Through the action alone: `BustBranding` is what makes it visible.
      CMS.save_site_branding!(%{twitter_site: "@after"}, authorize?: false, tenant: ctx.org_id)

      assert site_json()["twitter_site"] == "@after"
    end

    test "a reset answers the defaults again", ctx do
      brand!(ctx.org_id, %{site_name: "Reset Me", twitter_site: "@resetme"})
      assert site_json()["site_name"] == "Reset Me"

      [row] = CMS.list_site_branding!(tenant: ctx.org_id, authorize?: false)
      CMS.reset_site_branding!(row, authorize?: false, tenant: ctx.org_id)

      assert site_json() == %{
               "site_name" => "KilnCMS",
               "twitter_site" => nil,
               "social_image_url" => nil
             }
    end
  end

  describe "social_image_url" do
    test "a relative image is absolute on the default site's own host", ctx do
      brand!(ctx.org_id, %{social_image_url: "/uploads/brand.png"})

      assert site_json()["social_image_url"] == Tenant.base_url(ctx.org) <> "/uploads/brand.png"
    end

    test "a relative image is absolute on a subdomain site's host" do
      org = tenant("site-sub")
      brand!(org.id, %{social_image_url: "/uploads/sub.png"})

      url = site_json(on_host(org))["social_image_url"]
      assert url == Tenant.base_url(org) <> "/uploads/sub.png"
      assert URI.parse(url).host == "#{org.slug}.#{Tenant.base_host()}"
    end

    test "a relative image is absolute on a custom-domain site's host" do
      domain = "site-vanity-#{System.unique_integer([:positive])}.example.com"
      org = tenant("site-domain", custom_domain: domain)
      brand!(org.id, %{social_image_url: "/uploads/vanity.png"})

      url = site_json(%{build_conn() | host: domain})["social_image_url"]
      assert URI.parse(url).host == domain
      assert url == Tenant.base_url(org) <> "/uploads/vanity.png"
    end

    test "an absolute image passes through" do
      org = tenant("site-abs")
      brand!(org.id, %{social_image_url: "https://cdn.test/abs.png"})

      assert site_json(on_host(org))["social_image_url"] == "https://cdn.test/abs.png"
    end

    test "a relative operator image is absolute on each site's own host", ctx do
      Application.put_env(:kiln_cms, :branding, social_image_url: "/uploads/operator.png")
      org = tenant("site-op")
      KilnCMS.Cache.bust_branding(ctx.org_id)

      assert site_json()["social_image_url"] ==
               Tenant.base_url(ctx.org) <> "/uploads/operator.png"

      assert site_json(on_host(org))["social_image_url"] ==
               Tenant.base_url(org) <> "/uploads/operator.png"
    end
  end

  # Untagged on purpose: `:strict_tenancy` tests run only in the strict CI leg,
  # and the main suite is where a regression here must show.
  describe "tenancy" do
    test "each site answers its own values, never another's", ctx do
      b = tenant("site-b")
      c = tenant("site-c")

      brand!(ctx.org_id, %{
        site_name: "Default Site",
        twitter_site: "@defaultsite",
        social_image_url: "/uploads/default.png"
      })

      brand!(b.id, %{
        site_name: "Site B",
        twitter_site: "@siteb",
        social_image_url: "/uploads/b.png"
      })

      assert site_json() == %{
               "site_name" => "Default Site",
               "twitter_site" => "@defaultsite",
               "social_image_url" => Tenant.base_url(ctx.org) <> "/uploads/default.png"
             }

      assert site_json(on_host(b)) == %{
               "site_name" => "Site B",
               "twitter_site" => "@siteb",
               "social_image_url" => Tenant.base_url(b) <> "/uploads/b.png"
             }

      # An unbranded site gets the defaults, not the default org's row.
      c_conn = site(on_host(c))

      assert json_response(c_conn, 200) == %{
               "site_name" => "KilnCMS",
               "twitter_site" => nil,
               "social_image_url" => nil
             }

      refute c_conn.resp_body =~ "defaultsite"
      refute c_conn.resp_body =~ "siteb"
    end

    test "an unknown host is refused under strict host matching", ctx do
      brand!(ctx.org_id, %{twitter_site: "@defaultsite"})
      Application.put_env(:kiln_cms, :tenant_strict_host, true)

      host = "no-such-site-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"
      conn = site(%{build_conn() | host: host})

      assert conn.status == 404
      refute conn.resp_body =~ "defaultsite"
    end
  end

  describe "parity with the site's own pages" do
    test "twitter:site and the fallback og:image match on the default and a tenant host", ctx do
      org = tenant("site-parity")

      brand!(ctx.org_id, %{twitter_site: "@defaultsite", social_image_url: "/uploads/d.png"})
      brand!(org.id, %{twitter_site: "@paritysite", social_image_url: "/uploads/p.png"})

      # Pages with no image of their own, so `og:image` is the brand fallback.
      for {conn_fun, path} <- [{&build_conn/0, "/blog"}, {fn -> on_host(org) end, "/"}] do
        html = conn_fun.() |> get(path) |> html_response(200)
        api = site_json(conn_fun.())

        assert api["twitter_site"] == meta(html, "twitter:site")
        assert api["social_image_url"] == meta(html, "og:image")
        assert is_binary(api["social_image_url"])
      end
    end
  end

  describe "caching" do
    test "an anonymous read is public, with a weak ETag that answers 304", ctx do
      brand!(ctx.org_id, %{twitter_site: "@cached"})

      conn = site()
      assert conn.status == 200
      assert [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "public, max-age=60"
      assert [etag] = get_resp_header(conn, "etag")
      assert String.starts_with?(etag, "W/")
      assert get_resp_header(conn, "vary") |> Enum.join(",") =~ "authorization"

      revalidated = build_conn() |> put_req_header("if-none-match", etag) |> site()
      assert revalidated.status == 304
    end

    test "a valid API key is answered privately, with the same body", ctx do
      brand!(ctx.org_id, %{twitter_site: "@keyed"})

      anonymous = site_json()
      keyed = build_conn() |> put_req_header("authorization", "Bearer " <> api_key()) |> site()

      assert json_response(keyed, 200) == anonymous
      assert get_resp_header(keyed, "cache-control") == ["private, no-store"]
    end

    test "an invalid credential is a 401" do
      for bearer <- ["kiln_nonsense", "not-a-token"] do
        conn = build_conn() |> put_req_header("authorization", "Bearer " <> bearer) |> site()
        assert conn.status == 401, "Bearer #{bearer} was not refused"
      end
    end

    test "an unreadable branding row is a 503 that no cache keeps", ctx do
      brand!(ctx.org_id, %{site_name: "Branded"})

      # Resolve the host first, so the outage below reaches only the branding
      # read (the host lookup is cached; a failed branding read is not).
      assert site_json()["site_name"] == "Branded"
      KilnCMS.Cache.bust_branding(ctx.org_id)

      # The branding table is unresolvable on this connection, as it is
      # mid-deploy before its migration. SET, not DDL: reverted with the
      # sandbox transaction.
      KilnCMS.Repo.query!("SET search_path TO pg_catalog")

      conn = site()

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["2"]
      assert %{"errors" => [%{"code" => "temporarily_unavailable"}]} = json_response(conn, 503)
      refute conn.resp_body =~ "KilnCMS"
      refute Enum.any?(get_resp_header(conn, "cache-control"), &(&1 =~ "public"))
      assert get_resp_header(conn, "etag") == []

      # Nothing degraded was cached for the page path to pick up either.
      assert KilnCMS.Cache.peek(KilnCMS.Cache.branding_key(ctx.org_id)) == nil
    end
  end

  describe "CDN purge" do
    setup do
      Application.put_env(:kiln_cms, KilnCMS.CDN,
        purge_url: "https://purge.example.test/zones/z/purge_cache"
      )

      :ok
    end

    test "a reset purges the site's CDN key", ctx do
      brand!(ctx.org_id, %{twitter_site: "@purged"})
      [row] = CMS.list_site_branding!(tenant: ctx.org_id, authorize?: false)

      # The save above purged too; only the reset's job is under test.
      KilnCMS.Repo.delete_all(Oban.Job)
      CMS.reset_site_branding!(row, authorize?: false, tenant: ctx.org_id)

      assert_enqueued(worker: PurgeWorker, args: %{org_id: ctx.org_id})
    end
  end
end
