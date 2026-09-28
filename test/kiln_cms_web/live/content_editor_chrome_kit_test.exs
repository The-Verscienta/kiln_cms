defmodule KilnCMSWeb.ContentEditorChromeKitTest do
  @moduledoc """
  The content editor's chrome on the component kit (#1679).

    * The inspector rail's Preview / Settings / History switch is a kit
      `.tabs` tablist with the WAI-ARIA tabs pattern — the shape the Form
      Builder's got in #1680, sharing its `TabKeys` hook. Each tab names its
      panel, every panel stays mounted (so every `aria-controls` resolves),
      and only the selected tab is in the Tab order.
    * The block chrome stays keyboard-reachable: the controls fade in on
      `focus-within`, not only on hover.
    * The page actions keep their accessible names when they fold to icons.

  The arrow keys themselves live in `assets/js/tab_keys.js`, which
  LiveViewTest cannot run; `e2e/tests/editor_inspector_tabs.spec.js` drives
  them.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_editor do
    email = "chromekit-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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

  defp open_editor(conn) do
    page =
      Ash.Seed.seed!(Page, %{
        title: "Chrome kit",
        slug: "chrome-kit-#{System.unique_integer([:positive])}",
        state: :draft
      })

    {:ok, lv, _html} =
      conn |> log_in(authed_editor()) |> live(~p"/editor/content/page/#{page.id}")

    lv
  end

  describe "inspector tabs" do
    test "are a kit .tabs tablist wired to the shared TabKeys hook", %{conn: conn} do
      lv = open_editor(conn)

      assert has_element?(
               lv,
               ~s(#inspector-tabs.tabs[role="tablist"][aria-label="Inspector"][phx-hook="TabKeys"])
             )

      for tab <- ~w(preview settings history) do
        assert has_element?(
                 lv,
                 ~s(#inspector-tab-#{tab}.tab[role="tab"][aria-controls="inspector-panel-#{tab}"][phx-value-tab="#{tab}"])
               )

        # Every panel is mounted whichever tab shows, so every tab's
        # aria-controls points at a real element.
        assert has_element?(
                 lv,
                 ~s(#inspector-panel-#{tab}[role="tabpanel"][aria-labelledby="inspector-tab-#{tab}"])
               )
      end
    end

    test "only the selected tab is in the Tab order, and it moves with the selection",
         %{conn: conn} do
      lv = open_editor(conn)

      assert has_element?(lv, ~s(#inspector-tab-preview[aria-selected="true"][tabindex="0"]))
      assert has_element?(lv, ~s(#inspector-tab-settings[aria-selected="false"][tabindex="-1"]))
      assert has_element?(lv, ~s(#inspector-tab-history[aria-selected="false"][tabindex="-1"]))
      refute has_element?(lv, "#inspector-panel-preview.hidden")
      assert has_element?(lv, "#inspector-panel-settings.hidden")

      lv |> element("#inspector-tab-settings") |> render_click()

      assert has_element?(lv, ~s(#inspector-tab-settings[aria-selected="true"][tabindex="0"]))
      assert has_element?(lv, ~s(#inspector-tab-preview[aria-selected="false"][tabindex="-1"]))
      refute has_element?(lv, "#inspector-panel-settings.hidden")
      assert has_element?(lv, "#inspector-panel-preview.hidden")
    end
  end

  describe "block chrome" do
    test "fades in on keyboard focus as well as hover, on kit ghost buttons", %{conn: conn} do
      lv = open_editor(conn)
      render_hook(lv, "add_block", %{"type" => "rich_text"})

      [class] =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find(~s(#block-0 [role="group"][aria-label="Block actions"]))
        |> Floki.attribute("class")

      classes = String.split(class)

      # `focus-within` on the toolbar is what makes Tab onto a faded control
      # reveal it (#171); the rest widen when it shows, never narrow it.
      assert "opacity-0" in classes
      assert "focus-within:opacity-100" in classes
      assert "group-hover:opacity-100" in classes
      assert "group-focus-within:opacity-100" in classes
      assert "pointer-coarse:opacity-100" in classes

      for label <- ["Move block up", "Move block down", "Duplicate block", "Remove block"] do
        assert has_element?(lv, ~s(#block-0 button.btn.btn-ghost[aria-label="#{label}"]))
      end
    end
  end

  describe "page actions" do
    test "keep each label as the accessible name when they fold to icons", %{conn: conn} do
      lv = open_editor(conn)

      assert has_element?(lv, ~s(#editor-page-actions[role="group"]))

      # `max-2xl:sr-only`, never `hidden`: a display:none label would drop the
      # button's name along with its pixels.
      for label <- ["Media library", "Duplicate"] do
        assert has_element?(lv, "#editor-page-actions button span.max-2xl\\:sr-only", label)
      end
    end
  end
end
