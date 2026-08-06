defmodule KilnCMSWeb.ManifestControllerTest do
  @moduledoc """
  The installable editor PWA's web app manifest (#65).

  `async: false` — the per-org branding cases mutate application env and the
  shared Cachex, exactly like `KilnCMS.BrandingTest`.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Branding
  alias KilnCMS.CMS
  alias KilnCMSWeb.Tenant

  setup do
    original = Application.get_env(:kiln_cms, :branding)
    Application.put_env(:kiln_cms, :branding, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, :branding, original)
      KilnCMS.Cache.bust_branding(Accounts.default_org_id())
    end)

    :ok
  end

  describe "GET /manifest.webmanifest" do
    test "serves a manifest content type, not application/json", %{conn: conn} do
      conn = get(conn, ~p"/manifest.webmanifest")

      assert response(conn, 200)

      assert ["application/manifest+json" <> _] = get_resp_header(conn, "content-type")
    end

    test "is marked private/no-cache — it varies by org host and locale param", %{conn: conn} do
      conn = get(conn, ~p"/manifest.webmanifest")

      # A shared/CDN cache must never hand one org's (or one locale's) manifest
      # to another; the body carries no shared-cacheable value (#48, #630).
      assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
    end

    test "needs no authentication — the browser fetches it as a page subresource",
         %{conn: conn} do
      # No session at all: still 200, because a signed-out editor hitting
      # /sign-in inside the installed window must not 401 on the manifest.
      assert json_response(get(conn, ~p"/manifest.webmanifest"), 200)
    end

    test "starts on the review queue but scopes the whole origin", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest"), 200)

      # The mobile flow this exists for: land on what needs approving.
      assert body["start_url"] == "/editor?status=in_review"
      assert body["display"] == "standalone"

      # Scope must stay at the root: an unauthenticated launch redirects to
      # /sign-in, and anything outside `scope` opens in a browser tab instead.
      assert body["scope"] == "/"

      # A stable `id` decouples install identity from `start_url` — changing the
      # landing filter later must not orphan existing installs.
      assert body["id"] == "/editor"
    end

    test "declares the icon sizes Chromium requires to offer an install", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest"), 200)

      by_purpose = Enum.group_by(body["icons"], & &1["purpose"])

      assert Enum.sort(Enum.map(by_purpose["any"], & &1["sizes"])) == ["192x192", "512x512"]
      assert [%{"sizes" => "512x512"}] = by_purpose["maskable"]

      # `any` and `maskable` must be DIFFERENT images — a maskable icon carries a
      # 40% safe zone, so reusing it unmasked renders a tiny mark in a big tile.
      [any_512] = Enum.filter(by_purpose["any"], &(&1["sizes"] == "512x512"))
      [maskable] = by_purpose["maskable"]
      refute any_512["src"] == maskable["src"]
    end

    test "every icon and shortcut it advertises actually exists on disk", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest"), 200)

      srcs =
        body["icons"]
        |> Enum.concat(Enum.flat_map(body["shortcuts"], & &1["icons"]))
        |> Enum.map(& &1["src"])
        |> Enum.uniq()

      for src <- srcs do
        path = Path.join(Application.app_dir(:kiln_cms, "priv/static"), src)
        assert File.exists?(path), "manifest advertises #{src}, which is not in priv/static"
      end
    end

    test "shortcuts jump straight to a filtered queue", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest"), 200)

      urls = Enum.map(body["shortcuts"], & &1["url"])
      assert "/editor?status=in_review" in urls
      assert "/editor?status=draft" in urls
    end

    test "an unbranded site installs as KilnCMS in stock ember", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest"), 200)

      assert body["name"] == "KilnCMS Editor"
      assert body["short_name"] == "KilnCMS"
      assert body["theme_color"] == "#ff6200"
    end
  end

  describe "localization (#630)" do
    test "a non-default locale localizes the labels and gets its own install id", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest?locale=fr"), 200)

      assert body["name"] == "Éditeur KilnCMS"
      assert body["description"] == "Relisez, approuvez et publiez le contenu de KilnCMS."
      assert Enum.map(body["shortcuts"], & &1["name"]) == ["File de révision", "Brouillons"]

      # A distinct id so a fr install and an en install are separate apps —
      # switching the console language doesn't rename an already-installed one.
      assert body["id"] == "/editor?lang=fr"
    end

    test "the default locale keeps English strings and the historical id", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest?locale=en"), 200)

      assert body["name"] == "KilnCMS Editor"
      assert body["id"] == "/editor", "existing installs must not be orphaned"
    end

    test "an unsupported locale falls back to the default", %{conn: conn} do
      body = json_response(get(conn, ~p"/manifest.webmanifest?locale=zz"), 200)

      assert body["name"] == "KilnCMS Editor"
      assert body["id"] == "/editor"
    end
  end

  describe "per-org branding (#48)" do
    setup do
      org =
        Ash.Seed.seed!(Accounts.Organization, %{
          name: "Manifest Org",
          slug: "manifest-#{System.unique_integer([:positive])}",
          status: :active
        })

      admin =
        Ash.Seed.seed!(Accounts.User, %{
          email: "manifest-admin-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)

      %{org: org, admin: admin}
    end

    test "a white-labelled site installs under its own name and colour", ctx do
      CMS.save_site_branding!(%{site_name: "Acme Docs", brand_color: "#0f62fe"},
        actor: ctx.admin,
        tenant: ctx.org
      )

      body =
        ctx.conn
        |> org_host(ctx.org)
        |> get(~p"/manifest.webmanifest")
        |> json_response(200)

      assert body["name"] == "Acme Docs Editor"
      assert body["short_name"] == "Acme Docs"
      assert body["theme_color"] == "#0f62fe"
      assert body["description"] =~ "Acme Docs"
    end

    test "another org on the same instance gets its own manifest", ctx do
      CMS.save_site_branding!(%{site_name: "Acme Docs"}, actor: ctx.admin, tenant: ctx.org)

      # The default org is untouched by the tenant's branding row.
      assert Branding.for_org(nil).site_name == "KilnCMS"

      body = json_response(get(ctx.conn, ~p"/manifest.webmanifest"), 200)
      assert body["name"] == "KilnCMS Editor"
    end
  end

  defp org_host(conn, org), do: %{conn | host: "#{org.slug}.#{Tenant.base_host()}"}
end
