defmodule KilnCMSWeb.ContentEditorA11yTest do
  @moduledoc """
  The accessibility panel and its header chip (#495).

  The panel is the SEO panel's sibling — same registry, same rendering — so
  what is worth pinning here is the part that is NOT shared: that the two
  panels show different findings, and that neither leaks the other's noise.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "a11y-panel-#{System.unique_integer([:positive])}@example.com"

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

  defp page!(actor, blocks) do
    CMS.create_page!(
      %{title: "A11y fixture #{System.unique_integer([:positive])}", blocks: blocks},
      actor: actor
    )
  end

  defp para(text),
    do: %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}

  defp rich(nodes), do: %{"_type" => "rich_text", "body" => nodes}

  defp linked(text, label, key) do
    %{
      "_type" => "block",
      "style" => "normal",
      "children" => [
        %{"text" => text, "marks" => []},
        %{"text" => label, "marks" => [key]}
      ],
      "markDefs" => [%{"_type" => "link", "_key" => key, "href" => "/somewhere"}]
    }
  end

  describe "the panel" do
    test "renders as its own section, not buried inside SEO", %{conn: conn} do
      user = authed_user(:editor)
      page = page!(user, [rich([para("Some ordinary prose about nothing in particular.")])])

      {_lv, html} = open_editor(conn, user, page)

      assert html =~ "Accessibility"
      assert html =~ ~s(id="inspector-accessibility")
    end

    test "shows an accessibility finding the SEO panel's own checks wouldn't produce", %{
      conn: conn
    } do
      user = authed_user(:editor)
      page = page!(user, [rich([linked("Read ", "click here", "k1")])])

      {_lv, html} = open_editor(conn, user, page)

      assert html =~ "doesn&#39;t say where it goes" or html =~ "doesn't say where it goes"
    end

    test "reports an empty heading, which used to vanish from the walk entirely", %{conn: conn} do
      user = authed_user(:editor)

      page =
        page!(user, [
          # A Portable Text `h2` with no text, which is what TipTap leaves
          # behind when an author makes a heading and doesn't fill it in.
          #
          # NOT a typed `heading` block: that one requires `text`, and Ash
          # treats whitespace as blank, so it cannot hold an empty heading at
          # all. The rich-text path is the only way this defect is reachable.
          rich([
            %{"_type" => "block", "style" => "h2", "children" => [%{"text" => ""}]},
            para("Body text follows the empty heading.")
          ])
        ])

      {_lv, html} = open_editor(conn, user, page)

      assert html =~ "has no text"
    end

    test "an author with a clean document is told so rather than shown an empty box", %{
      conn: conn
    } do
      user = authed_user(:editor)

      page =
        page!(user, [
          %{"_type" => "heading", "level" => 2, "text" => "A clear heading"},
          rich([para("Short, readable prose with nothing wrong with it at all.")])
        ])

      {_lv, html} = open_editor(conn, user, page)

      assert html =~ "No accessibility issues found"
    end
  end

  describe "the two panels stay separate" do
    test "a search-only finding never reaches the accessibility panel", %{conn: conn} do
      # `thin_content` is the canonical case: a short page ranks badly and is
      # perfectly accessible.
      user = authed_user(:editor)
      page = page!(user, [rich([para("Three words here.")])])

      {_lv, html} = open_editor(conn, user, page)

      # It IS reported — in the SEO panel.
      assert html =~ "rarely rank well"

      # ...and the accessibility section, which renders before it, does not
      # repeat it. Sliced rather than searched, so this can't pass by finding
      # the SEO panel's copy.
      [a11y_section, _rest] = String.split(html, "SEO &amp; scheduling", parts: 2)
      refute a11y_section =~ "rarely rank well"
    end

    test "a shared finding reaches both — an author shouldn't fix it twice", %{conn: conn} do
      user = authed_user(:editor)

      page =
        page!(user, [
          %{"_type" => "heading", "level" => 1, "text" => "Title"},
          %{"_type" => "heading", "level" => 4, "text" => "Skipped down to four"},
          rich([para("Prose.")])
        ])

      {_lv, html} = open_editor(conn, user, page)

      [a11y_section, seo_section] = String.split(html, "SEO &amp; scheduling", parts: 2)

      assert a11y_section =~ "screen-reader users navigate by this outline"
      assert seo_section =~ "don&#39;t skip levels" or seo_section =~ "don't skip levels"
    end
  end

  describe "the header chip" do
    test "summarises the accessibility state and opens the Settings panel", %{conn: conn} do
      user = authed_user(:editor)
      page = page!(user, [rich([linked("Read ", "click here", "k1")])])

      {lv, html} = open_editor(conn, user, page)

      assert html =~ "a11y issue"

      # By id, not by the event/value pair: the inspector tab strip has its own
      # Settings button carrying exactly those attributes, so a selector on
      # them alone passes whether or not the chip renders at all.
      chip = lv |> element("#a11y-chip") |> render()

      assert chip =~ "a11y issue"
      # It reuses the tab strip's own event rather than a bespoke scroll hook,
      # so there is one code path that changes which panel is showing.
      assert chip =~ ~s(phx-click="switch_inspector_tab")
      assert chip =~ ~s(phx-value-tab="settings")
    end

    test "is absent on an empty draft, where there is nothing to judge", %{conn: conn} do
      # NOT gated on `report.total`: a passing check counts as applicable, so
      # an empty document reports {passed: 1, total: 1} and a `total > 0` gate
      # renders "Accessible" on a page with nothing in it.
      #
      # Asserted on the chip element rather than on a substring — HEEx puts
      # newlines around the label, so `html =~ "Accessible</button>"` never
      # matches and would pass with the chip fully visible.
      user = authed_user(:editor)
      page = page!(user, [])

      {lv, _html} = open_editor(conn, user, page)

      refute lv |> element("#a11y-chip") |> has_element?()
    end

    test "reads 'Accessible' once there is content and nothing wrong with it", %{conn: conn} do
      user = authed_user(:editor)

      page =
        page!(user, [
          %{"_type" => "heading", "level" => 2, "text" => "A clear heading"},
          rich([para("Short, readable prose with nothing wrong with it at all.")])
        ])

      {lv, _html} = open_editor(conn, user, page)

      assert lv |> element("#a11y-chip") |> render() =~ "Accessible"
    end
  end

  test "the SEO panel has real sentences for the shared new codes, not atom names",
       %{conn: conn} do
    # `LinkText` and the empty-heading finding report into BOTH panels, so the
    # SEO message table needs clauses for them too — without one they fall to
    # its catch-all and render as the bare code (`link_text_uninformative`),
    # untranslated.
    user = authed_user(:editor)

    page =
      page!(user, [
        rich([
          %{"_type" => "block", "style" => "h2", "children" => [%{"text" => ""}]},
          linked("Read ", "click here", "k1")
        ])
      ])

    {_lv, html} = open_editor(conn, user, page)

    refute html =~ "link_text_uninformative"
    refute html =~ "headings_empty"

    [_a11y, seo_section] = String.split(html, "SEO &amp; scheduling", parts: 2)
    assert seo_section =~ "anchor text tells search engines"
  end

  test "findings update live as the author types, and never block a save", %{conn: conn} do
    user = authed_user(:editor)
    page = page!(user, [rich([para("Some prose.")])])

    {lv, _html} = open_editor(conn, user, page)

    html =
      render_change(lv, "validate", %{
        "form" => %{"title" => "Still editable"},
        "_target" => ["form", "title"]
      })

    # The panel is present and the form is still submittable — advisories are
    # advice, and the author decides.
    assert html =~ "Accessibility"

    assert lv |> element(~s|button[type="submit"]:not([disabled])|) |> has_element?()
  end
end
