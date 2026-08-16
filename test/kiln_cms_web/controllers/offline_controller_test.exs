defmodule KilnCMSWeb.OfflineControllerTest do
  @moduledoc """
  The service worker's offline fallback, now per-org (#629).

  Two properties matter here and they pull against each other: the page has to
  carry the site's own branding, and it has to render with **no network at all**
  — it is served from the service worker's cache precisely when nothing else can
  be fetched. So every assertion about branding is paired with one that the
  branding did not arrive as a subresource.

  `async: false` — the branding cases mutate application env and the shared
  Cachex, like `KilnCMSWeb.ManifestControllerTest`.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  setup do
    original = Application.get_env(:kiln_cms, :branding)
    Application.put_env(:kiln_cms, :branding, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, :branding, original)
      KilnCMS.Cache.bust_branding(Accounts.default_org_id())
    end)

    :ok
  end

  defp body(conn), do: html_response(conn, 200)

  # The request resolves to the default org, so that is the row to write.
  defp brand!(attrs) do
    org = Accounts.default_org()

    CMS.save_site_branding!(attrs, actor: platform_admin(), tenant: org)
    KilnCMS.Cache.bust_branding(org.id)
    :ok
  end

  defp platform_admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "offline-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  describe "GET /offline.html" do
    test "renders an HTML page without authentication", %{conn: conn} do
      # The worker precaches it at install, before any navigation, and serves it
      # for a navigation that failed — including one the visitor was signed out
      # of. A redirect to /sign-in here would be a redirect the network cannot
      # follow.
      conn = get(conn, "/offline.html")

      assert body(conn) =~ "You&#39;re offline"
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
    end

    test "an unbranded site shows the stock name and ember", %{conn: conn} do
      html = body(get(conn, "/offline.html"))

      assert html =~ "KilnCMS"
      assert html =~ "#ff6200"
    end

    test "a white-labelled site shows its own name", %{conn: conn} do
      brand!(%{site_name: "Harbour Press"})

      html = body(get(conn, "/offline.html"))

      assert html =~ "Harbour Press"
      # The whole point of the issue: the KilnCMS mark must not be what a
      # reviewer for another publication sees when their train enters a tunnel.
      refute html =~ "KilnCMS"
    end

    test "the brand colour reaches the page as derived tokens, not raw", %{conn: conn} do
      brand!(%{site_name: "Harbour Press", brand_color: "#1d4ed8"})

      html = body(get(conn, "/offline.html"))

      {:ok, derived} = KilnCMS.Branding.Color.derive("#1d4ed8")

      # Both schemes, because the page has no stylesheet to switch: it carries
      # its own `prefers-color-scheme` block, and an accent solved only for one
      # background disappears against the other.
      assert html =~ derived.light_primary
      assert html =~ derived.dark_primary
    end

    test "a junk operator colour never reaches the stylesheet", %{conn: conn} do
      # This covers the BRANDING layer, not the controller's own `:error`
      # fallback: `Branding` drops an unparseable `BRAND_PRIMARY_COLOR` to nil
      # before the controller ever sees it, so what is asserted here is that the
      # junk does not survive that trip and the stock ember is what renders.
      # (No `#rrggbb` that `BrandTokens` accepts actually fails `Color.derive/1`
      # — the controller's `_unparseable` clause is defence, not a live path.)
      Application.put_env(:kiln_cms, :branding, primary_color: "not-a-colour")
      KilnCMS.Cache.bust_branding(Accounts.default_org_id())

      html = body(get(conn, "/offline.html"))

      assert html =~ "#ff6200"
      refute html =~ "not-a-colour"
    end
  end

  describe "it can render with no network" do
    setup %{conn: conn} do
      %{html: body(get(conn, "/offline.html"))}
    end

    test "no stylesheet, script, image, font or iframe", %{html: html} do
      # Each of these is a request. On the code path this page exists for, every
      # one of them fails — a missing stylesheet means unstyled text, a missing
      # logo means a broken-image icon on the page whose job is to look
      # deliberate.
      for tag <- ["<link", "<script", "<img", "<iframe", "@import", "url("] do
        refute html =~ tag, "the offline page must not reference #{tag}"
      end
    end

    test "the styling is inline, because a stylesheet would be a request", %{html: html} do
      assert html =~ "<style>"
    end

    test "the only link is a same-origin retry", %{html: html} do
      hrefs = Regex.scan(~r/href="([^"]*)"/, html, capture: :all_but_first)

      assert hrefs == [["/editor"]]
    end
  end

  describe "operator-supplied text is escaped" do
    test "a site name containing markup cannot close the style block or the title",
         %{conn: conn} do
      # An org admin is not the platform operator (the `BrandTokens` argument),
      # and this page is uniquely exposed: it is on `:probe`, which sets no CSP,
      # so escaping is the only thing between that value and the document.
      brand!(%{site_name: "</style><script>alert(1)</script>"})

      html = body(get(conn, "/offline.html"))

      refute html =~ "<script>"
      refute html =~ "</style><script"
      assert html =~ "&lt;/style&gt;"
    end
  end

  describe "it is safe to serve from a cache" do
    test "it stays out of SHARED caches, because the language varies by cookie",
         %{conn: conn} do
      # The manifest can say `public` because it puts the locale in the URL
      # (`?locale=`). This page cannot — the service worker precaches one URL —
      # so its language comes from the session, and a shared cache keyed on
      # host+path would hand the first requester's language to everyone else.
      conn = get(conn, "/offline.html")

      assert ["private, max-age=" <> _] = get_resp_header(conn, "cache-control")
    end

    test "it carries its own headers — nothing on :probe supplies them", %{conn: conn} do
      # The first HTML surface on the `:probe` pipeline, which has no
      # `put_secure_browser_headers`. `default-src 'none'` is exact rather than
      # merely strict here: the document loads nothing at all.
      conn = get(conn, "/offline.html")

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  describe "the service worker and the route agree" do
    test "sw.js precaches exactly the URL this controller serves", %{conn: conn} do
      # These two drifting apart is silent: the install-time `cache.add` rejects,
      # the worker never activates, and the only symptom is that offline shows
      # the browser's error page — the state this feature is supposed to end.
      sw = File.read!(Path.join(Application.app_dir(:kiln_cms, "priv/static"), "sw.js"))

      assert [[url]] =
               Regex.scan(~r/const OFFLINE_URL = "([^"]+)"/, sw, capture: :all_but_first)

      assert response(get(conn, url), 200)
    end

    test "a failed precache cannot abort the service-worker install" do
      # `/offline.html` used to be a `priv/static` file, which could not fail. It
      # is now a route behind a rate limiter and a branding lookup, so it can
      # 429 or 5xx — and a rejected `cache.add` inside `waitUntil` fails the
      # WHOLE installation: no fetch handler, no install prompt, and no web push
      # (#628), over a fallback page that is by definition optional.
      sw = File.read!(Path.join(Application.app_dir(:kiln_cms, "priv/static"), "sw.js"))

      assert sw =~ "async function cacheOffline()"
      assert sw =~ "catch"
      refute sw =~ "cache.add(new Request(OFFLINE_URL, {cache: \"reload\"}))\n      )"
    end

    test "a rebrand can still reach a device that already installed" do
      # Cache Storage ignores `Cache-Control`, and `install` only re-runs when
      # the bytes of sw.js change — so without a refresh a site that rebrands
      # after a device installed would show that device the old name forever.
      sw = File.read!(Path.join(Application.app_dir(:kiln_cms, "priv/static"), "sw.js"))

      assert sw =~ "OFFLINE_MAX_AGE_MS"
      assert sw =~ "refreshOffline"
    end

    test "the cache version was bumped past the one that held the static page" do
      # Without a bump the URL is unchanged, so an already-installed worker keeps
      # serving its cached copy of the old unbranded file forever.
      sw = File.read!(Path.join(Application.app_dir(:kiln_cms, "priv/static"), "sw.js"))

      assert [[version]] =
               Regex.scan(~r/\$\{CACHE_PREFIX\}v(\d+)/, sw, capture: :all_but_first)

      assert String.to_integer(version) >= 2
    end

    test "the old static file is gone, so the route is what answers" do
      # `Plug.Static` runs before the router. A leftover `priv/static/offline.html`
      # would shadow this controller and nothing would look wrong.
      refute File.exists?(
               Path.join(Application.app_dir(:kiln_cms, "priv/static"), "offline.html")
             )

      refute "offline.html" in KilnCMSWeb.static_paths()
    end
  end
end
