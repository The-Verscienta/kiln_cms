defmodule KilnCMSWeb.ConsoleKitConsistencyTest do
  @moduledoc """
  The console's shared furniture, screen by screen (#1678, #1680):

    * an empty list renders the kit `<.empty_state>` — a title, a line saying
      what would be here, and a next step where there is one — not a bare
      muted `<p>`;
    * the long settings pages carry an "On this page" contents whose every
      link lands on an id that is actually on the page;
    * the Form Builder's sections are a real ARIA tablist on the kit `.tabs`;
    * the "←" crumb above a screen points at its parent in `ConsoleNav`, not at
      the content list sixteen unrelated screens used to send you back to.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.ConsoleNav

  @password "password123456"

  defp authed_user(role) do
    email = "kit-#{System.unique_integer([:positive])}@example.com"

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

  defp mount(conn, role, path) do
    {:ok, lv, html} = conn |> log_in(authed_user(role)) |> live(path)
    {lv, html}
  end

  # The `<.empty_state>` markup: the dashed card, with its title and body.
  defp empty_state?(lv, id) do
    has_element?(lv, "##{id}.border-dashed") and
      has_element?(lv, "##{id} p.font-medium") and
      has_element?(lv, "##{id} p.max-w-sm")
  end

  describe "empty lists render <.empty_state> (#1678)" do
    test "trash", %{conn: conn} do
      {lv, _html} = mount(conn, :admin, ~p"/editor/trash")
      assert empty_state?(lv, "trash-empty")
      assert render(lv) =~ "Trash is empty."
    end

    test "inbox, with a way back from an empty Unread filter", %{conn: conn} do
      {lv, _html} = mount(conn, :editor, ~p"/editor/inbox")
      assert empty_state?(lv, "inbox-empty")
      refute has_element?(lv, "#inbox-empty a")

      {lv, _html} = mount(conn, :editor, ~p"/editor/inbox?filter=unread")
      assert empty_state?(lv, "inbox-empty")
      assert render(lv) =~ "Nothing unread."
      assert has_element?(lv, ~s(#inbox-empty a[href="/editor/inbox"]))
    end

    test "search palette with no hits", %{conn: conn} do
      {lv, _html} = mount(conn, :editor, ~p"/editor/search")
      refute has_element?(lv, "#search-empty")

      lv |> form("#palette-search", %{q: "zzqqxxnothingmatches"}) |> render_change()
      assert empty_state?(lv, "search-empty")
    end

    test "each taxonomy column", %{conn: conn} do
      {lv, _html} = mount(conn, :editor, ~p"/editor/taxonomy")

      for kind <- ~w(category tag_group tag) do
        assert empty_state?(lv, "taxonomy-empty-#{kind}")
      end
    end

    test "form builder entries", %{conn: conn} do
      admin = authed_user(:admin)

      form =
        CMS.create_form!(%{name: "Contact", slug: "kit-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")

      lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()
      assert empty_state?(lv, "form-submissions-empty")
    end
  end

  describe "long settings pages have a table of contents (#1680)" do
    for {path, toc} <- [
          {"/editor/settings", "settings-toc"},
          {"/editor/site-mail", "site-mail-toc"},
          {"/editor/mail", "mail-toc"}
        ] do
      test "#{path}: every contents link resolves to an id on the page", %{conn: conn} do
        {lv, html} = mount(conn, :admin, unquote(path))
        assert has_element?(lv, ~s(nav##{unquote(toc)}[aria-label="On this page"]))

        anchors =
          html
          |> LazyHTML.from_document()
          |> LazyHTML.query("##{unquote(toc)} a")
          |> LazyHTML.attribute("href")

        assert length(anchors) >= 4

        for "#" <> id <- anchors do
          assert has_element?(lv, "##{id}"),
                 "#{unquote(path)} links to ##{id}, which is not on the page"
        end
      end
    end
  end

  describe "Form Builder tabs (#1680)" do
    test "are a kit .tabs tablist with the ARIA tabs pattern", %{conn: conn} do
      admin = authed_user(:admin)

      form =
        CMS.create_form!(%{name: "Contact", slug: "kit-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")

      assert has_element?(lv, ~s(#form-builder-tabs.tabs[role="tablist"][phx-hook]))

      assert has_element?(
               lv,
               ~s(#form-builder-tab-fields.tab[role="tab"][aria-selected="true"][tabindex="0"][aria-controls="form-builder-panel"])
             )

      assert has_element?(
               lv,
               ~s(#form-builder-tab-general[role="tab"][aria-selected="false"][tabindex="-1"])
             )

      refute has_element?(lv, ~s(#form-builder-tab-general[aria-controls]))

      assert has_element?(
               lv,
               ~s(#form-builder-panel[role="tabpanel"][aria-labelledby="form-builder-tab-fields"])
             )

      lv |> element("#form-builder-tab-general") |> render_click()

      assert has_element?(lv, ~s(#form-builder-tab-general[aria-selected="true"][tabindex="0"]))
      assert has_element?(lv, ~s(#form-builder-tab-fields[aria-selected="false"][tabindex="-1"]))
      assert has_element?(lv, ~s(#form-builder-panel[aria-labelledby="form-builder-tab-general"]))
    end
  end

  describe "the ← crumb points at the screen's parent (#1680)" do
    @hub "/editor/configure#configure-group-"

    for {path, href} <- [
          {"/editor/team", @hub <> "operations"},
          {"/editor/accounts", @hub <> "operations"},
          {"/editor/billing", @hub <> "operations"},
          {"/editor/mail", @hub <> "operations"},
          {"/editor/system", @hub <> "operations"},
          {"/editor/webhooks", @hub <> "outbound"},
          {"/editor/automation", @hub <> "outbound"},
          {"/editor/types", @hub <> "content_model"},
          {"/editor/fields", @hub <> "content_model"},
          {"/editor/forms", @hub <> "capture"},
          # #1778: it said "← Analytics" while living under Capture.
          {"/editor/funnels", @hub <> "capture"},
          {"/editor/social", @hub <> "delivery"},
          {"/editor/newsletter", @hub <> "delivery"},
          {"/editor/trash", @hub <> "organization"},
          {"/editor/taxonomy", "/editor/overview"},
          {"/editor/analytics", "/editor/overview"},
          {"/editor/translations", "/editor/overview"}
        ] do
      test "#{path} → #{href}", %{conn: conn} do
        {lv, _html} = mount(conn, :admin, unquote(path))
        assert has_element?(lv, ~s(#console-crumb[href="#{unquote(href)}"]))
        refute render(lv) =~ "All content</a>"
      end
    end

    test "every hub anchor a crumb uses is a section on the hub", %{conn: conn} do
      {lv, _html} = mount(conn, :admin, ~p"/editor/configure")

      for key <- ~w(operations outbound content_model capture delivery organization) do
        assert has_element?(lv, "#configure-group-#{key}")
      end
    end
  end

  describe "ConsoleNav.parent/3" do
    test "a configure screen goes to its hub section for an admin" do
      assert %{label: "Configure", path: "/editor/configure#configure-group-operations"} =
               ConsoleNav.parent(authed_user(:admin), nil, :team)
    end

    test "falls back to Home for someone the hub is not shown to, and for author screens" do
      editor = authed_user(:editor)
      assert %{label: "Home", path: "/editor/overview"} = ConsoleNav.parent(editor, nil, :trash)
      assert %{path: "/editor/overview"} = ConsoleNav.parent(editor, nil, :taxonomy)
      assert %{path: "/editor/overview"} = ConsoleNav.parent(authed_user(:admin), nil, :nope)
    end
  end
end
