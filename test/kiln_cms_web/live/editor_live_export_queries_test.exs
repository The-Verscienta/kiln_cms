defmodule KilnCMSWeb.EditorLiveExportQueriesTest do
  @moduledoc """
  What the Export disclosure costs (#2293): rendering or filtering the list
  runs no export count (a `LIMIT cap + 1` read per type); opening the
  disclosure runs it once; and a list over the cap says so instead of giving a
  number.
  """
  # async: false — the counter attaches a global telemetry handler (see
  # `KilnCMS.Test.QueryCounting` for what keeps its counts this test's own), and
  # the over-cap test lowers the cap with `Application.put_env`, which every
  # other test in the VM would see.
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import KilnCMS.Test.QueryCounting
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    email = "expq-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  # An export count is the only list read bound with the cap plus one.
  defp export_counts(queries, cap) do
    Enum.filter(queries, fn %{params: params} -> is_list(params) and (cap + 1) in params end)
  end

  setup %{conn: conn} do
    prefix = "ExpQ#{uniq()}"

    for n <- 1..3 do
      Ash.Seed.seed!(Page, %{title: "#{prefix} #{n}", slug: "expq-#{uniq()}", state: :draft})
    end

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin())

    %{conn: conn, prefix: prefix}
  end

  test "no export count runs until the disclosure opens, then once", %{conn: conn, prefix: prefix} do
    cap = KilnCMSWeb.EditorLive.ListScope.export_cap()

    # Warm the one-off caches (registries, settings) so they are not counted.
    page_queries(conn, "/editor?type=page&q=#{prefix}")

    {lv, rendering} =
      queries(fn ->
        {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}&status=draft")
        render(lv)
        lv |> form("#content-filter", %{"status" => "draft"}) |> render_change()
        lv
      end)

    GenServer.stop(lv.pid)
    assert export_counts(rendering, cap) == []

    {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")

    {_, opening} = queries(fn -> lv |> element("#content-export-toggle") |> render_click() end)
    assert [_count] = export_counts(opening, cap)
    assert has_element?(lv, "#export-summary", "Export 3 matching")

    # Closing and opening again reads nothing: the figure stands until the
    # filter changes.
    {_, again} = queries(fn -> lv |> element("#content-export-toggle") |> render_click() end)
    assert export_counts(again, cap) == []
  end

  describe "over the cap" do
    setup do
      previous = Application.get_env(:kiln_cms, :content_export)
      Application.put_env(:kiln_cms, :content_export, max_rows: 2)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :content_export, previous),
          else: Application.delete_env(:kiln_cms, :content_export)
      end)
    end

    test "says to narrow the list and keeps the links", %{conn: conn, prefix: prefix} do
      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      lv |> element("#content-export-toggle") |> render_click()

      assert has_element?(lv, "#export-summary", "More than 2 rows — narrow the list first")
      refute has_element?(lv, "#export-summary", "matching")
      assert has_element?(lv, "#export-csv")
      assert has_element?(lv, "#export-json")
    end
  end
end
