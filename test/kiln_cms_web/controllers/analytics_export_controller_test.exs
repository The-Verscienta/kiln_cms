defmodule KilnCMSWeb.AnalyticsExportControllerTest do
  @moduledoc """
  Analytics export (#618, phase 1): editor-gated (not admin-only, unlike
  governance's export — `AnalyticsLive` itself is editor-visible), streamed
  CSV/JSON downloads of daily view buckets with titles resolved.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
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
      assert String.starts_with?(body, "day,content_type,content_id,title,views")
      assert body =~ "post,#{post.id},\"Exported, \"\"Post\"\"\",7"
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

      assert body =~ "post,#{missing_id},(deleted),2"
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

      assert body == "day,content_type,content_id,title,views\r\n"
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
