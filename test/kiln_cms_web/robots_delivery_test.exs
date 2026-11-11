defmodule KilnCMSWeb.RobotsDeliveryTest do
  @moduledoc """
  Per-document `noindex` / `nofollow` (#2256) on the delivery surfaces: the
  `<meta name="robots">` tag and `x-robots-tag` header (one helper builds both),
  the fired `:json` artifact, and the APIs. Delivery itself is unaffected —
  a noindex document is still served, synced and listed.
  """
  # async: false — the sync commit lag is app config, and delivery reads through
  # the shared content cache.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Firing.Sync)
    Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, commit_lag_seconds: 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, previous),
        else: Application.delete_env(:kiln_cms, KilnCMS.Firing.Sync)
    end)

    KilnCMS.Cache.bust_published()
    %{admin: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "robots-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "robots-#{System.unique_integer([:positive])}"

  defp published_page(admin, attrs \\ %{}) do
    page = CMS.create_page!(Map.merge(%{title: "Robots", slug: slug()}, attrs), actor: admin)
    CMS.publish_page!(page, actor: admin)
    KilnCMS.DataCase.drain_oban()
    Ash.reload!(page, authorize?: false, tenant: page.org_id)
  end

  defp robots_meta(html), do: html |> Floki.parse_document!() |> Floki.find("meta[name=robots]")

  describe "rendered page" do
    test "noindex sends the meta tag and the header", %{conn: conn, admin: admin} do
      page = published_page(admin, %{noindex: true})
      conn = get(conn, "/#{page.slug}")

      assert html_response(conn, 200)
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert [{"meta", attrs, _}] = robots_meta(conn.resp_body)
      assert {"content", "noindex"} in attrs
    end

    test "nofollow alone is honoured", %{conn: conn, admin: admin} do
      page = published_page(admin, %{nofollow: true})
      conn = get(conn, "/#{page.slug}")

      assert get_resp_header(conn, "x-robots-tag") == ["nofollow"]
      assert [{"meta", attrs, _}] = robots_meta(conn.resp_body)
      assert {"content", "nofollow"} in attrs
    end

    test "both flags combine", %{conn: conn, admin: admin} do
      page = published_page(admin, %{noindex: true, nofollow: true})
      conn = get(conn, "/#{page.slug}")

      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert [{"meta", attrs, _}] = robots_meta(conn.resp_body)
      assert {"content", "noindex, nofollow"} in attrs
    end

    test "a default document sends neither", %{conn: conn, admin: admin} do
      page = published_page(admin)
      conn = get(conn, "/#{page.slug}")

      assert html_response(conn, 200)
      assert get_resp_header(conn, "x-robots-tag") == []
      assert robots_meta(conn.resp_body) == []
    end

    test "a 304 revalidation carries the same header", %{conn: conn, admin: admin} do
      page = published_page(admin, %{noindex: true})

      first = get(conn, "/#{page.slug}")
      [etag] = get_resp_header(first, "etag")

      second = conn |> put_req_header("if-none-match", etag) |> get("/#{page.slug}")

      assert second.status == 304
      assert get_resp_header(second, "x-robots-tag") == ["noindex"]
    end

    test "an edit still in the working copy is not live until publish", %{
      conn: conn,
      admin: admin
    } do
      page = published_page(admin)

      {:ok, _} =
        CMS.save_page_working_copy(page, %{fields: %{"noindex" => true}},
          actor: admin,
          tenant: page.org_id
        )

      KilnCMS.Cache.bust_published()

      live = get(conn, "/#{page.slug}")
      assert get_resp_header(live, "x-robots-tag") == []

      page = Ash.reload!(page, authorize?: false, tenant: page.org_id)
      CMS.publish_page_changes!(page, actor: admin, tenant: page.org_id)
      KilnCMS.DataCase.drain_oban()
      KilnCMS.Cache.bust_published()

      published = get(conn, "/#{page.slug}")
      assert get_resp_header(published, "x-robots-tag") == ["noindex"]
    end

    test "the lock page stays noindex, nofollow whatever the flags say", %{
      conn: conn,
      admin: admin
    } do
      page = published_page(admin, %{access_password: "let me in please"})
      conn = get(conn, "/#{page.slug}")

      assert conn.status == 401
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert [{"meta", attrs, _}] = robots_meta(conn.resp_body)
      assert {"content", "noindex, nofollow"} in attrs
    end

    test "a redirect carries no directive", %{conn: conn, admin: admin} do
      page = published_page(admin, %{noindex: true, path_alias: "/ra-#{slug()}"})
      conn = get(conn, "/#{page.slug}")

      assert conn.status == 301
      assert get_resp_header(conn, "x-robots-tag") == []
    end
  end

  describe "helper" do
    test "builds the directive from the flags" do
      assert KilnCMSWeb.Robots.directive(%{noindex: false, nofollow: false}) == nil
      assert KilnCMSWeb.Robots.directive(%{noindex: true, nofollow: false}) == "noindex"
      assert KilnCMSWeb.Robots.directive(%{noindex: false, nofollow: true}) == "nofollow"
      assert KilnCMSWeb.Robots.directive(%{noindex: true, nofollow: true}) == "noindex, nofollow"
      assert KilnCMSWeb.Robots.directive(%{}) == nil
    end
  end

  describe "artifact and APIs" do
    test "the :json artifact carries the flags, and omits them by default", %{
      conn: conn,
      admin: admin
    } do
      flagged = published_page(admin, %{noindex: true})
      plain = published_page(admin)

      body = conn |> get(~p"/api/content/page/#{flagged.slug}") |> json_response(200)
      assert body["robots"] == %{"noindex" => true, "nofollow" => false}

      body = conn |> get(~p"/api/content/page/#{plain.slug}") |> json_response(200)
      # Absent on an ordinary document, on a body that is otherwise current:
      # `social` (#2258) is on every artifact of this build.
      refute Map.has_key?(body, "robots")
      assert Map.has_key?(body, "social")
    end

    test "JSON:API exposes the flags, including through sparse fields", %{
      conn: conn,
      admin: admin
    } do
      page = published_page(admin, %{noindex: true, nofollow: true})

      body =
        conn
        |> put_req_header("accept", @accept)
        |> get(
          "/api/json/pages/published?filter[slug]=#{page.slug}&fields[page]=noindex,nofollow"
        )
        |> json_response(200)

      assert [%{"attributes" => attrs}] = body["data"]
      assert attrs == %{"noindex" => true, "nofollow" => true}
    end

    test "GraphQL exposes the flags", %{conn: conn, admin: admin} do
      page = published_page(admin, %{noindex: true})

      query =
        ~s|{ publishedPages(filter: {slug: {eq: "#{page.slug}"}}) { results { noindex nofollow } } }|

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/gql", Jason.encode!(%{query: query}))
        |> json_response(200)

      assert %{
               "data" => %{
                 "publishedPages" => %{"results" => [%{"noindex" => true, "nofollow" => false}]}
               }
             } =
               body
    end

    test "sync still delivers a noindex document", %{conn: conn, admin: admin} do
      page = published_page(admin, %{noindex: true})

      body = conn |> get("/api/sync?initial=true&type=page") |> json_response(200)

      assert Enum.any?(body["items"], &(&1["id"] == page.id and &1["op"] == "upsert"))
    end
  end
end
