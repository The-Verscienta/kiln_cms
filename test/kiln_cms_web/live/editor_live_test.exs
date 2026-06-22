defmodule KilnCMSWeb.EditorLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_user(role) do
    email = "editor-#{System.unique_integer([:positive])}@example.com"

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

  defp draft_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "ed-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  describe "/editor (content list)" do
    test "viewers are redirected away", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in(authed_user(:viewer)) |> live(~p"/editor")
    end

    test "lists pages for an editor", %{conn: conn} do
      draft_page(%{title: "Findable Page"})
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ "Findable Page"
    end

    test "New page creates a draft and navigates to the editor", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element("button", "New page") |> render_click()

      assert {path, _flash} = assert_redirect(lv)
      assert path =~ ~r"^/editor/pages/"
    end
  end

  describe "/editor/pages/:id (block editor)" do
    test "saves an edited title", %{conn: conn} do
      page = draft_page(%{title: "Old title"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "New title"}) |> render_submit()

      assert CMS.get_page!(page.id, authorize?: false).title == "New title"
    end

    test "adds a block and persists its content", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[phx-value-type='heading']") |> render_click()

      lv
      |> form("#page-editor", form: %{blocks: %{"0" => %{content: "A nice heading"}}})
      |> render_submit()

      assert [%{type: :heading, content: "A nice heading"}] =
               CMS.get_page!(page.id, authorize?: false).blocks
    end

    test "reorders blocks via the sortable hook and persists the new order", %{conn: conn} do
      page =
        draft_page(%{
          blocks: [
            %{type: :heading, content: "A", order: 0},
            %{type: :rich_text, content: "B", order: 1}
          ]
        })

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Simulate the Sortable hook pushing the new order (B before A).
      render_hook(lv, "reorder", %{"order" => ["1", "0"]})
      lv |> form("#page-editor") |> render_submit()

      assert [%{content: "B"}, %{content: "A"}] =
               CMS.get_page!(page.id, authorize?: false).blocks
    end

    test "a rich_text block's HTML content round-trips through save", %{conn: conn} do
      # TipTap mirrors its HTML into a hidden input (server-rendered value); a
      # save round-trips it. (The live editing itself is browser-verified.)
      page =
        draft_page(%{
          blocks: [%{type: :rich_text, content: "<p>Hi <strong>there</strong></p>", order: 0}]
        })

      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # The rich_text block renders the TipTap mount + hidden input, not a textarea.
      assert html =~ ~s(phx-hook="RichText")

      lv |> form("#page-editor") |> render_submit()

      assert [%{type: :rich_text, content: "<p>Hi <strong>there</strong></p>"}] =
               CMS.get_page!(page.id, authorize?: false).blocks
    end

    test "the live preview reflects block content and updates on change", %{conn: conn} do
      page = draft_page(%{blocks: [%{type: :heading, content: "Original Heading", order: 0}]})
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Preview renders the heading block (distinct from the editor's textarea).
      assert html =~ ~s(text-xl font-bold">Original Heading)

      html2 =
        lv
        |> form("#page-editor", form: %{blocks: %{"0" => %{content: "Updated Heading"}}})
        |> render_change()

      assert html2 =~ ~s(text-xl font-bold">Updated Heading)
    end

    test "runs the publish workflow", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button", "Publish") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :published
    end
  end
end
