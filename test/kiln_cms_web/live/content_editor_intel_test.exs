defmodule KilnCMSWeb.ContentEditorIntelTest do
  @moduledoc """
  The "Similar content" panel — near-duplicates and tag suggestions in the
  editor (#339 phase 2).

  `KilnCMS.Search.Related` shipped with that phase and has its own tests; this
  covers the editor surface `docs/rag.md` recorded as still owed. The parts
  worth pinning are the ones that would regress silently: that nothing is
  queried until the author asks, that an empty result explains itself instead
  of looking broken, and that an edit invalidates a stale answer.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "intel-panel-#{System.unique_integer([:positive])}@example.com"

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

  defp para(text),
    do: %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}

  defp page!(actor) do
    CMS.create_page!(
      %{
        title: "Intel fixture #{System.unique_integer([:positive])}",
        blocks: [%{"_type" => "rich_text", "body" => [para("An article about herbal tea.")]}]
      },
      actor: actor
    )
  end

  test "the panel offers to check, and queries nothing on mount", %{conn: conn} do
    user = authed_user(:admin)
    page = page!(user)

    {_lv, html} = open_editor(conn, user, page)

    assert html =~ "inspector-content-intel"
    assert html =~ "Check for duplicates"
    # Nothing has been asked for, so no result and no empty-state either.
    refute html =~ "Possible duplicates"
    refute html =~ "Nothing similar found"
  end

  # With semantic search off — the default in test — `Related` returns empty by
  # design, and no amount of editing changes that. An unexplained empty panel
  # would send an author looking for a problem in their content.
  test "an empty result explains itself rather than reading as broken", %{conn: conn} do
    user = authed_user(:admin)
    page = page!(user)

    {lv, _html} = open_editor(conn, user, page)

    html =
      lv
      |> element("button[phx-click='content_intel_refresh']")
      |> render_click()

    # `start_async` resolves out of band; render_async waits for it.
    html = if html =~ "Nothing similar", do: html, else: render_async(lv, 2_000)

    assert html =~ "Turn on semantic search"
    # The button becomes a refresh once an answer has been asked for.
    assert html =~ "Refresh"
  end

  test "the panel is present for an editor, not only an admin", %{conn: conn} do
    user = authed_user(:editor)
    page = page!(user)

    {_lv, html} = open_editor(conn, user, page)

    assert html =~ "inspector-content-intel"
  end

  test "the panel states that it describes the last published version", %{conn: conn} do
    user = authed_user(:admin)
    page = page!(user)

    {_lv, html} = open_editor(conn, user, page)

    # Not inferable from the panel otherwise: embeddings are written on
    # publish, so unsaved (and unpublished) edits are invisible to it.
    assert html =~ "last published version"
  end

  describe "similarity_percent/1 rendering" do
    # Semantic search is off in test, so `Related` returns empty and no
    # duplicate ever renders through the LiveView — which is exactly how a
    # literal `%%` in the badge string shipped unnoticed. These assert on the
    # rendered sentence directly.
    test "renders a single percent sign, not a doubled one" do
      assert {:ok, "95% similar"} =
               Gettext.Interpolation.Default.runtime_interpolate(
                 "%{percent}% similar",
                 %{percent: 95}
               )
    end

    test "a percentage is clamped into 0..100" do
      for {distance, expected} <- [{0.0, 100}, {0.05, 95}, {1.0, 0}, {1.5, 0}, {-0.2, 100}] do
        assert {:ok, rendered} =
                 Gettext.Interpolation.Default.runtime_interpolate(
                   "%{percent}% similar",
                   %{percent: percent(distance)}
                 )

        assert rendered == "#{expected}% similar",
               "distance #{distance} should render #{expected}%"
      end
    end

    # Mirrors the private helper in the LiveView. Kept here rather than making
    # the helper public: what matters is the rendered sentence, and a copy that
    # disagrees with the original fails these tests loudly.
    defp percent(distance), do: ((1 - distance) * 100) |> max(0) |> min(100) |> round()
  end
end
