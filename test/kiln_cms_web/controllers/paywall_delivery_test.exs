defmodule KilnCMSWeb.PaywallDeliveryTest do
  @moduledoc """
  Gated content over the public HTML site (#337 Phase 2).

  `async: false`: the content cache is a global Cachex table while sandboxes are
  per-test, and the cache-crossing assertions below depend on real cache state.

  The cache tests are the important ones. `put_delivery_cache_headers/2` sends
  `public, max-age=60, stale-while-revalidate=300`, so a member's gated render
  escaping into a shared cache would be served to every anonymous visitor — the
  single most dangerous failure mode in this feature.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @body "SECRET-MEMBERS-ONLY-BODY"
  @password "password123456"

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "pw-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp member(audiences) do
    email = "pw-member-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :viewer,
      audiences: audiences
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp published_post(attrs) do
    actor = admin()

    {:ok, post} =
      CMS.create_post(
        Map.merge(
          %{
            title: "A gated piece",
            slug: "gated-#{System.unique_integer([:positive])}",
            excerpt: "The public teaser sentence.",
            blocks: [%{"_type" => "heading", "text" => @body, "level" => 2}]
          },
          attrs
        ),
        actor: actor
      )

    {:ok, published} = CMS.publish_post(post, %{}, actor: actor)
    published
  end

  describe "anonymous reader" do
    test "gets a 200 teaser instead of a 404", %{conn: conn} do
      post = published_post(%{audience: @gated})

      conn = get(conn, ~p"/blog/#{post.slug}")

      assert conn.status == 200
      assert html_response(conn, 200) =~ "A gated piece"
    end

    test "the teaser shows the summary but NEVER the body", %{conn: conn} do
      post = published_post(%{audience: @gated})

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ "The public teaser sentence."
      refute html =~ @body
    end

    test "the teaser links to the join page", %{conn: conn} do
      post = published_post(%{audience: @gated})

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ ~s(href="/membership")
    end

    test "a public post is unaffected — body served, public cache headers", %{conn: conn} do
      post = published_post(%{audience: :public})

      conn = get(conn, ~p"/blog/#{post.slug}")

      assert html_response(conn, 200) =~ @body

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=60, stale-while-revalidate=300"
             ]
    end

    test "an unknown slug still 404s", %{conn: conn} do
      conn = get(conn, ~p"/blog/no-such-post-at-all")

      assert conn.status == 404
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a DRAFT gated post 404s rather than teasing", %{conn: conn} do
      # The teaser must not become a draft-leak surface.
      {:ok, draft} =
        CMS.create_post(
          %{
            title: "Unpublished",
            slug: "draft-#{System.unique_integer([:positive])}",
            audience: @gated
          },
          actor: admin()
        )

      conn = get(conn, ~p"/blog/#{draft.slug}")

      assert conn.status == 404
    end
  end

  describe "entitled member" do
    test "gets the full body", %{conn: conn} do
      post = published_post(%{audience: @gated})
      conn = log_in(conn, member([@gated]))

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ @body
    end

    test "a signed-in reader WITHOUT the audience gets the teaser, not the body", %{conn: conn} do
      post = published_post(%{audience: @gated})
      conn = log_in(conn, member([]))

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      refute html =~ @body
      assert html =~ "The public teaser sentence."
    end
  end

  describe "cache and headers — the shared-cache hazard" do
    test "a member render is never shared-cacheable", %{conn: conn} do
      post = published_post(%{audience: @gated})
      conn = log_in(conn, member([@gated]))

      conn = get(conn, ~p"/blog/#{post.slug}")

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "vary") == ["Cookie, Accept-Language"]
    end

    test "a teaser is never shared-cacheable either", %{conn: conn} do
      # Same URL returns the full document for an entitled reader, so a shared
      # cache keyed on URL alone would eventually cross the two.
      post = published_post(%{audience: @gated})

      conn = get(conn, ~p"/blog/#{post.slug}")

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "a member request does NOT poison the cache for anonymous readers", %{conn: conn} do
      # THE regression test: member first, then anonymous.
      post = published_post(%{audience: @gated})

      member_html =
        conn |> log_in(member([@gated])) |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert member_html =~ @body

      anon_html = build_conn() |> get(~p"/blog/#{post.slug}") |> html_response(200)

      refute anon_html =~ @body
    end

    test "an anonymous teaser does not stick for an entitled member", %{conn: conn} do
      # ...and the other ordering.
      post = published_post(%{audience: @gated})

      anon_html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)
      refute anon_html =~ @body

      member_html =
        build_conn()
        |> log_in(member([@gated]))
        |> get(~p"/blog/#{post.slug}")
        |> html_response(200)

      assert member_html =~ @body
    end
  end

  describe "structured data" do
    test "a teaser is marked paywalled for crawlers", %{conn: conn} do
      post = published_post(%{audience: @gated})

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ "isAccessibleForFree"
      assert html =~ "kiln-paywalled"
    end

    test "the member render carries the SAME markers", %{conn: conn} do
      # A crawler and a subscriber disagreeing about whether a page is free is
      # exactly the cloaking signal search engines penalise.
      post = published_post(%{audience: @gated})
      conn = log_in(conn, member([@gated]))

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      assert html =~ "isAccessibleForFree"
    end

    test "a public post is NOT marked paywalled", %{conn: conn} do
      post = published_post(%{audience: :public})

      html = conn |> get(~p"/blog/#{post.slug}") |> html_response(200)

      refute html =~ "isAccessibleForFree"
    end
  end

  describe "blog index" do
    test "lists a gated post with a members badge rather than hiding it", %{conn: conn} do
      published_post(%{audience: @gated, title: "GatedHeadline"})

      html = conn |> get(~p"/blog") |> html_response(200)

      assert html =~ "GatedHeadline"
      assert html =~ "Members"
    end
  end

  describe "headless surfaces stay strict" do
    test "the artifact API still 404s for gated content", %{conn: conn} do
      # The `:api` pipeline has no `fetch_session`, so a browser cookie can never
      # authorize it — and this endpoint must not gain a teaser.
      post = published_post(%{audience: @gated})

      conn = get(conn, ~p"/api/content/post/#{post.slug}")

      assert conn.status == 404
    end
  end
end
