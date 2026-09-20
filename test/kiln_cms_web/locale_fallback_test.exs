defmodule KilnCMSWeb.LocaleFallbackTest do
  @moduledoc """
  Locale fallback chains across every delivery surface: the fired-artifact
  API, `/api/resolve`, `/api/menus`, the JSON:API and GraphQL by-slug reads,
  the built-in site and `/api/locales`.

  The test config runs `en`, `fr` and `es`, so the chains here are spelled
  `es → fr → en` rather than the `fr-CA → fr → en` the docs use — the shape is
  the same.

  `async: false` because the chains are per-org settings cached by org id, and
  most of this runs on the default org every other delivery test shares: a
  concurrent test reading `/es/…` while this module has `es` chained to French
  would see French. `on_exit` busts the cache, since the row rolls back with
  the sandbox but the cache does not.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @passphrase "correct horse battery staple"
  @schema KilnCMSWeb.GraphqlSchema

  setup do
    on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(Accounts.default_org_id()) end)
    %{actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fallback-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "fb-#{System.unique_integer([:positive])}"

  defp chains!(fallbacks, org_id \\ Accounts.default_org_id()) do
    CMS.save_site_locale_settings!(%{fallbacks: fallbacks}, authorize?: false, tenant: org_id)
  end

  # A published page with its artifact fired, so the artifact API serves it.
  defp published(actor, slug, locale, attrs \\ %{}) do
    page =
      CMS.create_page!(Map.merge(%{title: "#{locale} title", slug: slug, locale: locale}, attrs),
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    page
  end

  defp served(conn),
    do: {get_resp_header(conn, "x-kiln-locale"), get_resp_header(conn, "content-language")}

  describe "GET /api/content/:type/:slug" do
    test "walks the site's chain and says which locale it served", %{conn: conn, actor: actor} do
      chains!(%{"es" => ["fr", "en"]})
      s = slug()
      published(actor, s, "fr")
      published(actor, s, "en")

      conn = get(conn, ~p"/api/content/page/#{s}?locale=es")

      assert json_response(conn, 200)["title"] == "fr title"
      assert served(conn) == {["fr"], ["fr"]}
      assert [etag] = get_resp_header(conn, "etag")
      assert etag =~ "-fr-json-"
    end

    test "a locale with no configured chain falls back to the default locale", %{
      conn: conn,
      actor: actor
    } do
      s = slug()
      published(actor, s, "en")

      conn = get(conn, ~p"/api/content/page/#{s}?locale=es")

      assert json_response(conn, 200)["title"] == "en title"
      assert served(conn) == {["en"], ["en"]}
    end

    test "a chain of [] never falls back", %{conn: conn, actor: actor} do
      chains!(%{"es" => []})
      s = slug()
      published(actor, s, "en")

      assert conn |> get(~p"/api/content/page/#{s}?locale=es") |> json_response(404)
    end

    test "a chain is taken as written, without a silent last hop to the default", %{
      conn: conn,
      actor: actor
    } do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "en")

      assert conn |> get(~p"/api/content/page/#{s}?locale=es") |> json_response(404)
    end

    test "?fallback=false serves the requested locale or nothing — even when the chain's answer is cached",
         %{conn: conn, actor: actor} do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr")

      # Warm the `es` entry with the French record the chain landed on.
      assert conn |> get(~p"/api/content/page/#{s}?locale=es") |> json_response(200)

      assert build_conn()
             |> get(~p"/api/content/page/#{s}?locale=es&fallback=false")
             |> json_response(404)

      conn = get(build_conn(), ~p"/api/content/page/#{s}?locale=fr&fallback=false")
      assert json_response(conn, 200)["title"] == "fr title"
      assert served(conn) == {["fr"], ["fr"]}
    end

    test "?fallback_locale= replaces the site's chain", %{conn: conn, actor: actor} do
      chains!(%{"es" => ["fr", "en"]})
      s = slug()
      published(actor, s, "fr")
      published(actor, s, "en")

      conn = get(conn, ~p"/api/content/page/#{s}?locale=es&fallback_locale=en")

      assert json_response(conn, 200)["title"] == "en title"
      assert served(conn) == {["en"], ["en"]}
    end

    test "the requested locale always wins when it exists", %{conn: conn, actor: actor} do
      chains!(%{"es" => ["fr", "en"]})
      s = slug()
      published(actor, s, "es")
      published(actor, s, "fr")

      conn = get(conn, ~p"/api/content/page/#{s}?locale=es")
      assert json_response(conn, 200)["title"] == "es title"
      assert served(conn) == {["es"], ["es"]}
    end

    test "an unsupported locale is a 400 naming /api/locales, not the default", %{
      conn: conn,
      actor: actor
    } do
      s = slug()
      published(actor, s, "en")

      for path <- [
            "/api/content/page/#{s}?locale=de",
            "/api/content/page/#{s}?locale[]=fr",
            "/api/content/page/#{s}?fallback_locale=de"
          ] do
        assert %{"errors" => [%{"code" => "unsupported_locale", "detail" => detail}]} =
                 conn |> get(path) |> json_response(400)

        assert detail =~ "/api/locales"
      end

      assert %{"errors" => [%{"code" => "invalid_fallback"}]} =
               conn |> get("/api/content/page/#{s}?fallback=maybe") |> json_response(400)
    end

    test "a chain change is served on the next request, not after the cache TTL", %{
      conn: conn,
      actor: actor
    } do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr")
      published(actor, s, "en")

      assert get(conn, ~p"/api/content/page/#{s}?locale=es")
             |> json_response(200)
             |> Map.get("title") ==
               "fr title"

      chains!(%{"es" => ["en"]})

      assert get(build_conn(), ~p"/api/content/page/#{s}?locale=es")
             |> json_response(200)
             |> Map.get("title") == "en title"
    end

    test "publishing the requested translation replaces the fallback it was being served", %{
      conn: conn,
      actor: actor
    } do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr")

      assert get(conn, ~p"/api/content/page/#{s}?locale=es")
             |> json_response(200)
             |> Map.get("title") ==
               "fr title"

      published(actor, s, "es")

      assert get(build_conn(), ~p"/api/content/page/#{s}?locale=es")
             |> json_response(200)
             |> Map.get("title") == "es title"
    end

    test "a locked variant on the chain answers 401, and unlock verifies that same document", %{
      conn: conn,
      actor: actor
    } do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr", %{access_password: @passphrase})

      assert %{"errors" => [%{"code" => "password_required"}]} =
               conn |> get(~p"/api/content/page/#{s}?locale=es") |> json_response(401)

      token =
        build_conn()
        |> post(~p"/api/content/page/#{s}/unlock?locale=es", %{"passphrase" => @passphrase})
        |> json_response(200)
        |> Map.fetch!("token")

      conn =
        build_conn()
        |> put_req_header("x-kiln-unlock", token)
        |> get(~p"/api/content/page/#{s}?locale=es")

      assert json_response(conn, 200)["title"] == "fr title"
      assert served(conn) == {["fr"], ["fr"]}
    end
  end

  describe "GET /api/content/:type/:slug/related" do
    test "resolves its anchor through the chain, and refuses an unsupported locale", %{
      conn: conn,
      actor: actor
    } do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr")

      conn = get(conn, ~p"/api/content/page/#{s}/related?locale=es")

      assert %{"locale" => "fr"} = json_response(conn, 200)
      assert served(conn) == {["fr"], ["fr"]}

      assert %{"errors" => [%{"code" => "unsupported_locale"}]} =
               build_conn()
               |> get(~p"/api/content/page/#{s}/related?locale=de")
               |> json_response(400)
    end
  end

  describe "GET /api/resolve" do
    test "resolves through the chain and reports the locale found", %{conn: conn, actor: actor} do
      chains!(%{"es" => ["fr"]})
      s = slug()
      page = published(actor, s, "fr")

      conn = get(conn, ~p"/api/resolve?path=/#{s}&locale=es")

      assert %{"status" => "ok", "id" => id, "locale" => "fr"} = json_response(conn, 200)
      assert id == page.id
      assert served(conn) == {["fr"], ["fr"]}
    end

    test "an unsupported locale is a 400 here too", %{conn: conn} do
      assert %{"errors" => [%{"code" => "unsupported_locale"}]} =
               conn |> get(~p"/api/resolve?path=/anything&locale=de") |> json_response(400)
    end

    test "each site resolves through its own chain", %{conn: conn} do
      other = org("fallback-tenant")
      on_exit(fn -> KilnCMS.Cache.bust_locale_fallbacks(other.id) end)
      s = slug()

      for org_id <- [Accounts.default_org_id(), other.id] do
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "English",
          slug: s,
          locale: "en",
          state: :published,
          org_id: org_id
        })
      end

      # The default org refuses to fall back from `es`; the other site has no
      # row, so it takes the implicit hop to the default locale.
      chains!(%{"es" => []})

      assert conn |> get(~p"/api/resolve?path=/#{s}&locale=es") |> json_response(404)

      assert %{"locale" => "en"} =
               build_conn()
               |> org_conn(other)
               |> get(~p"/api/resolve?path=/#{s}&locale=es")
               |> json_response(200)
    end
  end

  describe "GET /api/menus/:key" do
    defp menu(key, locale, name) do
      CMS.create_menu!(%{key: key, name: name, locale: locale}, authorize?: false)
    end

    test "follows a configured chain and names the variant served", %{conn: conn} do
      key = "fbnav-#{System.unique_integer([:positive])}"
      menu(key, "fr", "Principal")
      chains!(%{"es" => ["fr"]})

      conn = get(conn, ~p"/api/menus/#{key}?locale=es")

      assert %{"locale" => "fr", "name" => "Principal"} = json_response(conn, 200)
      assert served(conn) == {["fr"], ["fr"]}
    end

    test "never takes the implicit hop to the default locale on its own", %{conn: conn} do
      key = "fbnav-#{System.unique_integer([:positive])}"
      menu(key, "en", "Main")

      assert conn |> get(~p"/api/menus/#{key}?locale=es") |> json_response(404)

      # …but a request that names the fallback gets it.
      assert %{"locale" => "en"} =
               build_conn()
               |> get(~p"/api/menus/#{key}?locale=es&fallback_locale=en")
               |> json_response(200)
    end

    test "an unsupported locale is a 400, not the default menu", %{conn: conn} do
      key = "fbnav-#{System.unique_integer([:positive])}"
      menu(key, "en", "Main")

      assert %{"errors" => [%{"code" => "unsupported_locale"}]} =
               conn |> get(~p"/api/menus/#{key}?locale=de") |> json_response(400)
    end
  end

  describe "JSON:API /by-slug/:slug" do
    defp json_api(path) do
      build_conn() |> put_req_header("accept", "application/vnd.api+json") |> get(path)
    end

    test "resolves through the chain and says which locale it served", %{actor: actor} do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr")

      conn = json_api("/api/json/pages/by-slug/#{s}?locale=es")

      assert %{"data" => %{"attributes" => %{"locale" => "fr", "title" => "fr title"}}} =
               Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert served(conn) == {["fr"], ["fr"]}

      assert json_api("/api/json/pages/by-slug/#{s}?locale=es&fallback=false").status == 404
    end

    test "an unsupported locale is refused", %{actor: actor} do
      s = slug()
      published(actor, s, "en")

      assert json_api("/api/json/pages/by-slug/#{s}?locale=de").status == 400
    end

    # AshJsonApi reads every public read argument off the query string, the
    # action's delivery-widening `audiences`/`unlocks` included. The route
    # authorizes, so the `Content` read policies must still keep a gated
    # variant from an anonymous caller who names its audience — the walk then
    # moves on down the chain rather than serving it.
    test "naming an audience in the query string does not widen an anonymous read", %{
      actor: actor
    } do
      chains!(%{"es" => ["fr", "en"]})
      s = slug()
      published(actor, s, "fr", %{audience: :member})
      published(actor, s, "en")

      conn = json_api("/api/json/pages/by-slug/#{s}?locale=es&audiences[]=member")

      assert %{"data" => %{"attributes" => %{"locale" => "en"}}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GraphQL" do
    defp run(query, variables),
      do:
        Absinthe.run(query, @schema,
          variables: variables,
          context: %{tenant: Accounts.default_org_id()}
        )

    test "pageBySlug walks the chain; fallback: false narrows it; an unsupported locale errors",
         %{actor: actor} do
      chains!(%{"es" => ["fr"]})
      s = slug()
      published(actor, s, "fr")

      query = """
      query ($slug: String!, $locale: String!, $fallback: Boolean) {
        pageBySlug(slug: $slug, locale: $locale, fallback: $fallback) { title locale }
      }
      """

      assert {:ok, %{data: %{"pageBySlug" => %{"locale" => "fr", "title" => "fr title"}}}} =
               run(query, %{"slug" => s, "locale" => "es"})

      assert {:ok, %{data: %{"pageBySlug" => nil}}} =
               run(query, %{"slug" => s, "locale" => "es", "fallback" => false})

      assert {:ok, %{errors: [_ | _]}} = run(query, %{"slug" => s, "locale" => "de"})
    end

    test "menu follows a configured chain", %{} do
      key = "fbgql-#{System.unique_integer([:positive])}"
      CMS.create_menu!(%{key: key, name: "Principal", locale: "fr"}, authorize?: false)
      chains!(%{"es" => ["fr"]})

      query = """
      query ($key: String!, $locale: String) { menu(key: $key, locale: $locale) { locale name } }
      """

      assert {:ok, %{data: %{"menu" => %{"locale" => "fr"}}}} =
               run(query, %{"key" => key, "locale" => "es"})

      assert {:ok, %{errors: [%{message: message}]}} =
               run(query, %{"key" => key, "locale" => "de"})

      assert message =~ "not a locale this site serves"
    end
  end

  describe "the built-in site" do
    test "serves the chain's answer with the served locale on the page and the response", %{
      conn: conn
    } do
      chains!(%{"es" => ["fr"]})
      s = slug()

      for locale <- ["fr", "en"] do
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "#{locale} page",
          slug: s,
          locale: locale,
          state: :published
        })
      end

      conn = get(conn, "/es/#{s}")
      html = html_response(conn, 200)

      assert html =~ "fr page"
      assert html =~ ~s(lang="fr")
      assert get_resp_header(conn, "content-language") == ["fr"]
    end

    test "honours a chain that refuses to fall back", %{conn: conn} do
      chains!(%{"es" => []})
      s = slug()

      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "English",
        slug: s,
        locale: "en",
        state: :published
      })

      assert conn |> get("/es/#{s}") |> response(404)
    end
  end

  describe "GET /api/locales" do
    test "publishes each locale's effective chain", %{conn: conn} do
      chains!(%{"es" => ["fr", "en"], "fr" => []})

      assert %{"fallbacks" => %{"es" => ["fr", "en"], "fr" => [], "en" => []}} =
               conn |> get(~p"/api/locales") |> json_response(200)
    end
  end
end
