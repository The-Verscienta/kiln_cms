defmodule KilnCMSWeb.AnalyticsExportControllerTest do
  @moduledoc """
  Analytics export (#618, phase 1): editor-gated (not admin-only, unlike
  governance's export — `AnalyticsLive` itself is editor-visible), streamed
  CSV/JSON downloads of daily view buckets with titles resolved.
  """
  # async: false — the "referrer export" describe block below mutates the
  # global :analytics_referrers Application env, which an async: true sibling
  # test (e.g. KilnCMS.AnalyticsTest's "off by default" assertion, or this
  # file's own "off by default" test) could observe mid-mutation. See #620
  # review.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "analytics-export-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
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

  defp slug, do: "aec-#{System.unique_integer([:positive])}"

  defp seed_bucket(attrs) do
    Ash.Seed.seed!(
      ContentViewDay,
      Map.merge(%{content_type: "page", content_id: Ash.UUID.generate(), views: 1}, attrs)
    )
  end

  defp today, do: Date.utc_today()

  describe "tier gate" do
    test "anonymous requests are forbidden", %{conn: conn} do
      conn = get(conn, ~p"/editor/analytics/export.csv")
      assert conn.status == 403
    end

    test "viewers are forbidden", %{conn: conn} do
      conn = conn |> log_in(authed_user(:viewer)) |> get(~p"/editor/analytics/export.csv")
      assert conn.status == 403
    end

    test "editors may export (unlike the admin-only governance export)", %{conn: conn} do
      conn = conn |> log_in(authed_user(:editor)) |> get(~p"/editor/analytics/export.csv")
      assert conn.status == 200
    end

    test "admins may export", %{conn: conn} do
      conn = conn |> log_in(authed_user(:admin)) |> get(~p"/editor/analytics/export.csv")
      assert conn.status == 200
    end
  end

  describe "CSV export" do
    test "returns a header and one row per bucket, with the title resolved", %{conn: conn} do
      admin = authed_user(:admin)
      post = CMS.create_post!(%{title: "Exported, \"Post\"", slug: slug()}, actor: admin)
      CMS.publish_post!(post, %{}, actor: admin)

      seed_bucket(%{content_type: "post", content_id: post.id, day: today(), views: 7})

      response =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )

      assert response.status == 200
      assert response.resp_headers |> List.keyfind("content-type", 0) |> elem(1) =~ "text/csv"

      body = response.resp_body
      assert String.starts_with?(body, "kind,day,content_type,content_id,title,views,source,hits")
      assert body =~ "view,#{today()},post,#{post.id},\"Exported, \"\"Post\"\"\",7,,"
    end

    test "content that has since been deleted exports as \"(deleted)\"", %{conn: conn} do
      admin = authed_user(:admin)
      missing_id = Ash.UUID.generate()
      seed_bucket(%{content_type: "post", content_id: missing_id, day: today(), views: 2})

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert body =~ "view,#{today()},post,#{missing_id},(deleted),2,,"
    end

    test "an empty window still returns just the header", %{conn: conn} do
      admin = authed_user(:admin)
      far_future = Date.add(today(), 300)

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(far_future), to: Date.to_iso8601(far_future)]}"
        )
        |> Map.fetch!(:resp_body)

      assert body ==
               "kind,day,content_type,content_id,title,views,source,hits,funnel_slug,ratio\r\n"
    end
  end

  describe "JSON export" do
    test "returns a JSON array of buckets with titles resolved", %{conn: conn} do
      admin = authed_user(:admin)

      seed_bucket(%{
        content_type: "page",
        content_id: Ash.UUID.generate(),
        day: today(),
        views: 3
      })

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.json?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert [row] = Jason.decode!(body)
      assert row["views"] == 3
      assert row["content_type"] == "page"
    end

    test "an empty window returns an empty JSON array", %{conn: conn} do
      admin = authed_user(:admin)
      far_future = Date.add(today(), 300)

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.json?#{[from: Date.to_iso8601(far_future), to: Date.to_iso8601(far_future)]}"
        )
        |> Map.fetch!(:resp_body)

      assert Jason.decode!(body) == []
    end

    test "anonymous requests are forbidden", %{conn: conn} do
      conn = get(conn, ~p"/editor/analytics/export.json")
      assert conn.status == 403
    end

    # The comma-prefix logic in stream_json/2 only proves itself across a
    # batch boundary — a single-batch fixture can't tell a correct `sent_any?`
    # apart from one that's always false.
    test "produces valid JSON across more than one internal batch", %{conn: conn} do
      admin = authed_user(:admin)

      # 600 distinct content items viewed on the same day — one batch (500)
      # plus a second, so the reduce's `sent_any?` comma logic actually
      # crosses a batch boundary rather than always seeing `false`.
      for _ <- 1..600 do
        seed_bucket(%{
          content_type: "page",
          content_id: Ash.UUID.generate(),
          day: today(),
          views: 1
        })
      end

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.json?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      rows = Jason.decode!(body)
      assert length(rows) == 600
    end
  end

  describe "referrer export (#620)" do
    alias KilnCMS.Analytics.ReferrerDay

    setup do
      original = Application.get_env(:kiln_cms, :analytics_referrers, [])
      on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, original) end)
      :ok
    end

    defp enable_referrers(threshold \\ 5) do
      Application.put_env(:kiln_cms, :analytics_referrers,
        enabled: true,
        low_count_threshold: threshold
      )
    end

    defp seed_referrer_bucket(attrs) do
      Ash.Seed.seed!(
        ReferrerDay,
        Map.merge(
          %{content_type: "page", content_id: Ash.UUID.generate(), source: :direct, hits: 1},
          attrs
        )
      )
    end

    test "off by default: no referrer rows even when buckets exist", %{conn: conn} do
      seed_referrer_bucket(%{day: today(), source: :search, hits: 9})

      body =
        conn
        |> log_in(authed_user(:admin))
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      refute body =~ "referrer,"
    end

    test "CSV: a referrer row is kind-tagged, with views left blank", %{conn: conn} do
      enable_referrers()
      id = Ash.UUID.generate()
      seed_referrer_bucket(%{content_id: id, day: today(), source: :search, hits: 9})

      body =
        conn
        |> log_in(authed_user(:admin))
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert body =~ "referrer,#{today()},page,#{id},(deleted),,search,9"
    end

    test "CSV: a referrer count below the threshold is suppressed as \"< n\"", %{conn: conn} do
      enable_referrers(5)
      id = Ash.UUID.generate()
      seed_referrer_bucket(%{content_id: id, day: today(), source: :social, hits: 2})

      body =
        conn
        |> log_in(authed_user(:admin))
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert body =~ "referrer,#{today()},page,#{id},(deleted),,social,< 5"
      refute body =~ ",social,2"
    end

    test "JSON: view and referrer rows are both present, kind-tagged", %{conn: conn} do
      enable_referrers()
      admin = authed_user(:admin)

      post = CMS.create_post!(%{title: "With Referrers", slug: slug()}, actor: admin)
      CMS.publish_post!(post, %{}, actor: admin)

      seed_bucket(%{content_type: "post", content_id: post.id, day: today(), views: 4})
      seed_referrer_bucket(%{content_id: post.id, day: today(), source: :internal, hits: 6})

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.json?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      rows = Jason.decode!(body)
      assert Enum.find(rows, &(&1["kind"] == "view" and &1["views"] == 4))

      assert Enum.find(
               rows,
               &(&1["kind"] == "referrer" and &1["source"] == "internal" and &1["hits"] == 6)
             )
    end

    test "JSON: a suppressed referrer count exports as the \"< n\" string, not the exact number",
         %{conn: conn} do
      enable_referrers(5)
      id = Ash.UUID.generate()
      seed_referrer_bucket(%{content_id: id, day: today(), source: :other, hits: 1})

      body =
        conn
        |> log_in(authed_user(:admin))
        |> get(
          ~p"/editor/analytics/export.json?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert [row] = Jason.decode!(body)
      assert row["hits"] == "< 5"
    end
  end

  describe "funnel export (#622)" do
    defp funnel_with_steps!(admin, steps) do
      funnel =
        Analytics.create_funnel!(
          %{name: "Signup", slug: "aec-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      for {content_type, content_id, position} <- steps do
        Analytics.create_funnel_step!(
          %{
            funnel_id: funnel.id,
            content_type: content_type,
            content_id: content_id,
            position: position
          },
          actor: admin
        )
      end

      funnel
    end

    test "CSV: a funnel step row is kind-tagged, with day/source/hits left blank",
         %{conn: conn} do
      admin = authed_user(:admin)
      id = Ash.UUID.generate()
      seed_bucket(%{content_type: "page", content_id: id, day: today(), views: 8})
      funnel = funnel_with_steps!(admin, [{"page", id, 0}])

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert body =~ "funnel_step,,page,#{id},(deleted),8,,,#{funnel.slug},\r\n"
    end

    test "CSV: the ratio column carries the population-ratio percent", %{conn: conn} do
      admin = authed_user(:admin)
      landing = Ash.UUID.generate()
      pricing = Ash.UUID.generate()
      seed_bucket(%{content_type: "page", content_id: landing, day: today(), views: 20})
      seed_bucket(%{content_type: "page", content_id: pricing, day: today(), views: 5})

      funnel_with_steps!(admin, [{"page", landing, 0}, {"page", pricing, 1}])

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      assert body =~ "funnel_step,,page,#{pricing},(deleted),5,,,"
      assert body =~ ",25.0\r\n"
    end

    test "an inactive funnel is omitted from the export", %{conn: conn} do
      admin = authed_user(:admin)
      id = Ash.UUID.generate()
      seed_bucket(%{content_type: "page", content_id: id, day: today(), views: 1})
      funnel = funnel_with_steps!(admin, [{"page", id, 0}])
      Analytics.update_funnel!(funnel, %{active: false}, actor: admin)

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      refute body =~ "funnel_step,"
    end

    test "JSON: a funnel step row carries funnel_slug and ratio, no day key", %{conn: conn} do
      admin = authed_user(:admin)
      id = Ash.UUID.generate()
      seed_bucket(%{content_type: "page", content_id: id, day: today(), views: 8})
      funnel = funnel_with_steps!(admin, [{"page", id, 0}])

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.json?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      rows = Jason.decode!(body)
      assert [row] = Enum.filter(rows, &(&1["kind"] == "funnel_step"))
      assert row["funnel_slug"] == funnel.slug
      assert row["views"] == 8
      refute Map.has_key?(row, "day")
    end
  end

  describe "range validation" do
    test "rejects an invalid date", %{conn: conn} do
      conn =
        conn
        |> log_in(authed_user(:editor))
        |> get(~p"/editor/analytics/export.csv?#{[from: "not-a-date"]}")

      assert conn.status == 400
      assert json_response(conn, 400)["error"] == "invalid_date"
    end

    test "rejects from after to", %{conn: conn} do
      conn =
        conn
        |> log_in(authed_user(:editor))
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(Date.add(today(), -1))]}"
        )

      assert conn.status == 400
      assert json_response(conn, 400)["error"] == "from_after_to"
    end

    test "rejects a span wider than the retention window", %{conn: conn} do
      too_wide_from = Date.add(today(), -ContentViewDay.retention_days())

      conn =
        conn
        |> log_in(authed_user(:editor))
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(too_wide_from), to: Date.to_iso8601(today())]}"
        )

      assert conn.status == 400
      assert json_response(conn, 400)["error"] == "range_too_large"
    end

    # The AC is "capped at the retention ceiling" — exactly `retention_days`
    # must still be accepted, not just rejected one day past it.
    test "accepts a span of exactly the retention window", %{conn: conn} do
      exact_from = Date.add(today(), -(ContentViewDay.retention_days() - 1))

      conn =
        conn
        |> log_in(authed_user(:editor))
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(exact_from), to: Date.to_iso8601(today())]}"
        )

      assert conn.status == 200
    end

    test "a non-string date param is rejected, not a 500", %{conn: conn} do
      conn =
        conn
        |> log_in(authed_user(:editor))
        |> get(~p"/editor/analytics/export.csv?to[nested]=1")

      assert conn.status == 400
      assert json_response(conn, 400)["error"] == "invalid_date"
    end
  end

  describe "streaming" do
    test "the response is chunked rather than a single materialized body", %{conn: conn} do
      conn = conn |> log_in(authed_user(:admin)) |> get(~p"/editor/analytics/export.csv")
      assert conn.state == :chunked
    end
  end

  describe "tenant isolation" do
    test "another org's buckets never appear in this org's export", %{conn: conn} do
      admin = authed_user(:admin)
      other_org = KilnCMS.OrgFixtures.org("aec-other")
      foreign_id = Ash.UUID.generate()

      seed_bucket(%{
        content_type: "page",
        content_id: foreign_id,
        day: today(),
        views: 42,
        org_id: other_org.id
      })

      body =
        conn
        |> log_in(admin)
        |> get(
          ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
        )
        |> Map.fetch!(:resp_body)

      refute body =~ foreign_id
    end
  end
end
