defmodule KilnCMSWeb.ReferrerViewTrackingTest do
  @moduledoc """
  Referrer attribution (#619) joins the existing view-tracking write, gated
  off by default. No test here can produce a stored row containing a host or
  URL — the classified atom is all `ReferrerDay.:record` accepts.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ReferrerDay
  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rvt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "rvt-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Referred",
          slug: slug,
          blocks: [%{type: :heading, content: "Hi", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
  end

  defp enable_referrers do
    original = Application.get_env(:kiln_cms, :analytics_referrers, [])
    Application.put_env(:kiln_cms, :analytics_referrers, enabled: true)
    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, original) end)
  end

  defp buckets_for(page) do
    ReferrerDay |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.content_id == page.id))
  end

  test "off by default: a referer header is present but nothing is stored", %{conn: conn} do
    page = published_page()

    conn
    |> put_req_header("referer", "https://www.google.com/search?q=x")
    |> get(~p"/#{page.slug}")

    assert buckets_for(page) == []
  end

  test "enabled: a search-engine referer records a :search bucket", %{conn: conn} do
    enable_referrers()
    page = published_page()

    conn
    |> put_req_header("referer", "https://www.google.com/search?q=x")
    |> get(~p"/#{page.slug}")

    assert [%{source: :search, hits: 1}] = buckets_for(page)
  end

  test "enabled: no referer header records a :direct bucket", %{conn: conn} do
    enable_referrers()
    page = published_page()

    get(conn, ~p"/#{page.slug}")

    assert [%{source: :direct, hits: 1}] = buckets_for(page)
  end

  # The one category that depends on production input (`conn.host`, not a
  # literal test string) rather than the classifier's own compile-time table
  # — this is the actual production comparison, not a stand-in for it.
  test "enabled: a referer on the request's own host records an :internal bucket", %{conn: conn} do
    enable_referrers()
    page = published_page()

    conn
    |> put_req_header("referer", "https://#{conn.host}/some-other-page")
    |> get(~p"/#{page.slug}")

    assert [%{source: :internal, hits: 1}] = buckets_for(page)
  end

  test "enabled: an unrecognized referer host records an :other bucket", %{conn: conn} do
    enable_referrers()
    page = published_page()

    conn
    |> put_req_header("referer", "https://a-random-blog.example/post")
    |> get(~p"/#{page.slug}")

    assert [%{source: :other, hits: 1}] = buckets_for(page)
  end

  test "enabled: repeated arrivals from the same source increment one bucket", %{conn: conn} do
    enable_referrers()
    page = published_page()

    for _ <- 1..3 do
      conn
      |> put_req_header("referer", "https://www.facebook.com/")
      |> get(~p"/#{page.slug}")
    end

    assert [%{source: :social, hits: 3}] = buckets_for(page)
  end

  test "enabled: the view and view-day counters still record alongside the referrer bucket",
       %{conn: conn} do
    enable_referrers()
    page = published_page()

    get(conn, ~p"/#{page.slug}")

    assert [%{views: 1}] =
             Analytics.list_views!(authorize?: false) |> Enum.filter(&(&1.content_id == page.id))

    assert [%{source: :direct}] = buckets_for(page)
  end

  describe "headless (artifact) surface" do
    # Firing is async (#201): drain before the request, otherwise the API
    # answers 503 and nothing is delivered to count — see
    # artifact_view_tracking_test.exs.
    defp fired_page do
      page = published_page()
      KilnCMS.DataCase.drain_oban()
      page
    end

    test "an artifact fetch classifies its referer the same way as the HTML surface",
         %{conn: conn} do
      enable_referrers()
      page = fired_page()

      conn
      |> put_req_header("referer", "https://www.google.com/search?q=x")
      |> get(~p"/api/content/page/#{page.slug}")

      assert [%{source: :search, hits: 1}] = buckets_for(page)
    end

    test "a server-to-server fetch with no referer records :direct, honestly", %{conn: conn} do
      enable_referrers()
      page = fired_page()

      get(conn, ~p"/api/content/page/#{page.slug}")

      assert [%{source: :direct, hits: 1}] = buckets_for(page)
    end
  end
end
