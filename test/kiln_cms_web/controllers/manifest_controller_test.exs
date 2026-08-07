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

  # #630. The strings are translated now, but only because the URL carries the
  # locale: a manifest is fetched once per install and the OS keeps the label it
  # got forever, so translating against the *request's* locale from one URL would
  # name the installed app after whichever locale happened to fetch first.
  describe "localization (#630)" do
    setup do
      # `config/test.exs` already configures en/fr/es, so nothing is set here —
      # only saved, for the one case below that deliberately narrows the set.
      previous = Application.get_env(:kiln_cms, :i18n)
      on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)
      :ok
    end

    defp manifest(conn, query \\ "") do
      json_response(get(conn, "/manifest.webmanifest" <> query), 200)
    end

    test "the default locale is unchanged, including its install id", %{conn: conn} do
      body = manifest(conn)

      assert body["name"] == "KilnCMS Editor"
      assert body["lang"] == "en"
      assert body["id"] == "/editor"
    end

    test "a locale-scoped fetch is translated end to end", %{conn: conn} do
      body = manifest(conn, "?locale=fr")

      assert body["name"] == "Éditeur KilnCMS"
      assert body["description"] =~ "Relisez"
      assert body["lang"] == "fr"

      # Shortcut labels too — they are OS-surfaced (long-press the icon), so they
      # belong in the installing user's language for the same reason.
      assert Enum.map(body["shortcuts"], & &1["name"]) == [
               "File d'attente de révision",
               "Brouillons"
             ]
    end

    test "the install id does not vary by locale", %{conn: conn} do
      # #630 suggested a distinct `id` per locale. Deliberately not done: a
      # manifest whose id doesn't match an installed app's is not a rename, it
      # makes the browser DISCARD the whole update — so a pre-existing install
      # whose session locale isn't the default would stop receiving icon,
      # theme_color, scope and branding changes forever, and be offered again as
      # a second app. It is also unstable under `default_locale`, an
      # operator-facing setting: flipping that would orphan every install.
      for query <- ["", "?locale=fr", "?locale=es", "?locale=de"] do
        assert manifest(conn, query)["id"] == "/editor",
               "expected a locale-independent install id for #{inspect(query)}"
      end
    end

    test "translating does not disturb anything an installed app keys on", %{conn: conn} do
      # The fields a manifest update carries besides the labels. If any of these
      # moved per locale, an installed app would render differently depending on
      # which locale last refreshed it.
      en = manifest(conn)
      fr = manifest(conn, "?locale=fr")

      for key <- ~w(id start_url scope display theme_color background_color icons) do
        assert en[key] == fr[key], "#{key} must not vary by locale"
      end

      # Shortcut *targets* are stable too — only their labels move.
      assert Enum.map(en["shortcuts"], & &1["url"]) == Enum.map(fr["shortcuts"], & &1["url"])
    end

    test "the brand name is not translated — it is a proper noun", %{conn: conn} do
      body = manifest(conn, "?locale=fr")
      assert body["short_name"] == "KilnCMS"
      assert body["name"] =~ "KilnCMS"
    end

    test "an unsupported or junk locale falls back to the default", %{conn: conn} do
      # This endpoint is unauthenticated and the parameter is raw client input —
      # it must not 404, and it must not be trusted straight into Gettext.
      for query <- ["?locale=de", "?locale=", "?locale=../../etc/passwd", "?locale[]=fr"] do
        body = manifest(conn, query)
        assert body["lang"] == "en", "expected #{query} to fall back to the default locale"
        assert body["name"] == "KilnCMS Editor"
      end
    end

    test "a locale outside the configured set is refused even if Gettext knows it",
         %{conn: conn} do
      # `es` is only honoured because the setup above configures it. Narrow the
      # set and it must fall back, rather than serving a locale the operator
      # deliberately does not run.
      Application.put_env(:kiln_cms, :i18n, default_locale: "en", locales: ["en"])

      body = manifest(conn, "?locale=es")
      assert body["lang"] == "en"
      assert body["name"] == "KilnCMS Editor"
    end

    test "a locale-scoped fetch does not bleed into the next request on that process",
         %{conn: conn} do
      # `Gettext.put_locale/2` is per-process and Phoenix reuses connection
      # processes, so this controller DOES leave the process set to `fr`. What
      # makes that safe is `KilnCMSWeb.Plugs.SetLocale` being an ENDPOINT plug:
      # it runs before the router on every routed request and resets the locale.
      # Move it into a router pipeline and this endpoint (which is in `:probe`)
      # would start serving French to whoever came next.
      #
      # Asserted through a second real request rather than on the process
      # dictionary, because the reset is the invariant that matters — the leak
      # itself is expected.
      assert manifest(conn, "?locale=fr")["lang"] == "fr"

      unscoped = manifest(conn)
      assert unscoped["lang"] == "en"
      assert unscoped["name"] == "KilnCMS Editor"
    end

    test "the response carries an explicit cache policy", %{conn: conn} do
      # The response varies by query string and this is deployed behind a CDN;
      # without a policy of its own it inherits whatever the front door does.
      conn = get(conn, "/manifest.webmanifest?locale=fr")

      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      # No `Vary` — the locale is in the URL, not a request header.
      assert get_resp_header(conn, "vary") == []
    end

    test "a translated manifest still carries the org's branding", %{conn: conn} do
      # The two axes are independent: #48 decides the name, #630 the language.
      body = manifest(conn, "?locale=fr")
      assert body["theme_color"] == "#ff6200"
      assert body["short_name"] == "KilnCMS"
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
