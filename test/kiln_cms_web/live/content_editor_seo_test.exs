defmodule KilnCMSWeb.ContentEditorSeoTest do
  @moduledoc """
  The SEO & readability panel in the content editor (#476): a traffic-light
  grade in the panel header and a live, non-blocking findings checklist that
  updates as the author types. Nothing here ever blocks a save.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "seo-panel-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  defp change(lv, field, params) do
    render_change(lv, "validate", %{"form" => params, "_target" => ["form", field]})
  end

  # Ten short, readable paragraphs — enough to clear the thin-content floor,
  # with the keyphrase only in the opening few so density stays in band.
  defp prose_blocks do
    body =
      for i <- 1..10 do
        opener =
          if i <= 3,
            do: "The kiln firing step #{i} is simple. ",
            else: "Step #{i} is just as simple. "

        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [
            %{
              "text" =>
                opener <>
                  "Load the shelves with care. " <>
                  "Set the ramp rate low for the first hour. Watch the cones as the heat climbs. " <>
                  "Let the work cool in the closed kiln before you open it."
            }
          ]
        }
      end

    [
      %{"_type" => "heading", "text" => "Understanding kiln firing", "level" => 2},
      %{"_type" => "rich_text", "body" => body}
    ]
  end

  describe "the panel renders on mount" do
    test "a bare draft shows the grade badge and a missing-description warning", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Bare Draft", slug: "bare-seo"}, actor: editor)
      {_lv, html} = open_editor(conn, editor, page)

      assert html =~ "SEO &amp; scheduling"
      assert html =~ "search engines will invent one"
      # Warnings present, so the badge is not green.
      assert html =~ "Needs work" or html =~ "Poor"
    end

    test "an empty draft is never a wall of failures", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Empty", slug: "empty-seo"}, actor: editor)
      {_lv, html} = open_editor(conn, editor, page)

      # Checks with nothing to judge stay :n_a rather than shouting at an
      # author who has only just started.
      refute html =~ "rarely rank well"
      refute html =~ "No headings"
      refute html =~ "no alt text"
    end
  end

  describe "findings update live as the author types" do
    test "an over-long SEO title is reported with its measured length", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Length", slug: "length-seo"}, actor: editor)
      {lv, _html} = open_editor(conn, editor, page)

      html =
        change(lv, "seo_title", %{
          "title" => "Length",
          "slug" => "length-seo",
          "seo_title" => String.duplicate("a", 61)
        })

      assert html =~ "SEO title is 61 characters"
    end

    test "filling the description clears its warning", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Desc", slug: "desc-seo"}, actor: editor)
      {lv, html} = open_editor(conn, editor, page)

      assert html =~ "search engines will invent one"

      html =
        change(lv, "seo_description", %{
          "title" => "Desc",
          "slug" => "desc-seo",
          "seo_description" =>
            "A practical guide to kiln firing schedules, covering ramp rates, soak times and cone packs for the studio potter."
        })

      refute html =~ "search engines will invent one"
    end
  end

  describe "body-derived findings" do
    test "a page with images missing alt text reports an error", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Gallery",
            slug: "gallery-seo",
            blocks: prose_blocks() ++ [%{"_type" => "image", "url" => "/a.jpg", "alt" => ""}]
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)

      assert html =~ "no alt text"
      assert html =~ "Poor"
    end

    test "thin content is reported with its word count", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Stub",
            slug: "stub-seo",
            blocks: [
              %{
                "_type" => "rich_text",
                "body" => [
                  %{
                    "_type" => "block",
                    "style" => "normal",
                    "children" => [%{"text" => "Only a handful of words live here."}]
                  }
                ]
              }
            ]
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)
      assert html =~ "rarely rank well"
    end
  end

  describe "a well-formed page" do
    test "shows the good grade and no findings at all", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Understanding kiln firing",
            slug: "kiln-firing",
            seo_title: "Understanding kiln firing schedules for beginners",
            seo_description:
              "A practical guide to kiln firing schedules, covering ramp rates, soak times and cone packs for the studio potter.",
            seo_keywords: "kiln firing, glaze",
            seo_image: "/uploads/kiln.jpg",
            blocks: prose_blocks()
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)

      assert html =~ "Good"
      refute html =~ "rarely rank well"
      refute html =~ "search engines will invent one"
      refute html =~ "focus keyphrase"
    end
  end

  describe "body stats stay fresh" do
    # The editor caches the body walk behind a hash of the typed blocks, so a
    # bug there would show up as findings frozen at their mount-time values.
    test "editing the body updates body-derived findings", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Gallery",
            slug: "fresh-seo",
            blocks: [%{"_type" => "image", "url" => "/a.jpg", "alt" => "A loaded kiln"}]
          },
          actor: editor
        )

      {lv, html} = open_editor(conn, editor, page)

      refute html =~ "no alt text"

      # Clearing the alt in the body must move the finding, not serve a cached
      # answer from mount.
      html =
        lv
        |> form("#page-editor")
        |> render_change(%{"form" => %{"blocks" => %{"0" => %{"alt" => ""}}}})

      assert html =~ "no alt text"

      # ...and restoring it must clear the finding again.
      html =
        lv
        |> form("#page-editor")
        |> render_change(%{"form" => %{"blocks" => %{"0" => %{"alt" => "A loaded kiln"}}}})

      refute html =~ "no alt text"
    end
  end

  describe "analysis never blocks a save" do
    test "a page with every warning still saves", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Messy", slug: "messy-seo"}, actor: editor)
      {lv, _html} = open_editor(conn, editor, page)

      html =
        change(lv, "seo_title", %{"title" => "Messy", "slug" => "messy-seo", "seo_title" => "x"})

      # The analysis complains loudly...
      assert html =~ "SEO title is short"

      # ...and the save goes through anyway. Findings are advice, never gates.
      lv |> form("#page-editor", form: %{seo_title: "x"}) |> render_submit()

      assert Ash.get!(KilnCMS.CMS.Page, page.id, actor: editor).seo_title == "x"
    end
  end
end
