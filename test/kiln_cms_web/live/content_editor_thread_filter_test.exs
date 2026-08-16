defmodule KilnCMSWeb.ContentEditorThreadFilterTest do
  @moduledoc """
  Narrowing the block tree to blocks that need attention.

  The filter hides with CSS rather than by dropping blocks from the render, so
  what these tests check is the *state* each block card advertises and the
  container's filter attribute — the two things the stylesheet rule keys on.
  A block that stopped being rendered would take its form inputs with it, and
  the next save would drop that block's fields entirely.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "filter-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: "Filter #{System.unique_integer([:positive])}"
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

  defp page(actor) do
    CMS.create_page!(
      %{
        title: "Filter spec",
        slug: "filter-#{System.unique_integer([:positive])}",
        blocks: [
          %{"_type" => "quote", "text" => "Discussed"},
          %{"_type" => "heading", "text" => "Settled"},
          %{"_type" => "heading", "text" => "Quiet"}
        ]
      },
      actor: actor
    )
  end

  defp block_id(page, index),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  # What each block card advertises to the stylesheet.
  defp card_state(html, block_id) do
    case Regex.run(
           ~r/data-block-id="#{Regex.escape(block_id)}"\s+data-block-threads="(\w+)"/,
           html,
           capture: :all_but_first
         ) do
      [state] -> state
      nil -> nil
    end
  end

  defp filter_attr(html) do
    case Regex.run(~r/id="blocks-sortable"[^>]*data-thread-filter="(\w+)"/, html,
           capture: :all_but_first
         ) do
      [value] -> value
      nil -> nil
    end
  end

  setup %{conn: conn} do
    editor = authed_user(:editor)
    target = page(editor)

    CMS.add_comment!(
      %{
        content_type: "page",
        content_id: target.id,
        block_id: block_id(target, 0),
        body: "Still open"
      },
      actor: editor
    )

    settled =
      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: block_id(target, 1),
          body: "Was open"
        },
        actor: editor
      )

    CMS.resolve_comment!(settled, %{}, actor: editor)

    %{conn: log_in(conn, editor), page: target, editor: editor}
  end

  test "every block card advertises its own discussion state", ctx do
    {:ok, _lv, html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")

    assert card_state(html, block_id(ctx.page, 0)) == "unresolved"
    assert card_state(html, block_id(ctx.page, 1)) == "resolved"
    assert card_state(html, block_id(ctx.page, 2)) == "empty"
  end

  test "the chip counts blocks needing attention, and is off by default", ctx do
    {:ok, _lv, html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")

    assert html =~ "1 unresolved discussion"
    assert html =~ ~s(aria-pressed="false")
    assert is_nil(filter_attr(html))
  end

  test "toggling it filters, and toggling again clears it", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")

    html = render_click(lv, "toggle_thread_filter", %{})
    assert filter_attr(html) == "unresolved"
    assert html =~ "Showing only blocks that need attention."

    html = render_click(lv, "toggle_thread_filter", %{})
    assert is_nil(filter_attr(html))
    refute html =~ "Showing only blocks that need attention."
  end

  # The whole reason this is a CSS filter: a block dropped from the render
  # takes its inputs with it, and the next save drops that block's fields.
  test "filtering never removes a block from the form", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")
    html = render_click(lv, "toggle_thread_filter", %{})

    for index <- 0..2 do
      assert card_state(html, block_id(ctx.page, index)) != nil
      assert html =~ ~s(value="#{block_id(ctx.page, index)}")
    end
  end

  test "?threads=unresolved lands pre-filtered", ctx do
    {:ok, _lv, html} =
      live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}?threads=unresolved")

    assert filter_attr(html) == "unresolved"
    assert html =~ ~s(aria-pressed="true")
  end

  test "an unknown threads value lands unfiltered rather than empty", ctx do
    {:ok, _lv, html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}?threads=nonsense")

    assert is_nil(filter_attr(html))
  end

  # A control that could only ever hide everything is noise.
  test "the chip is absent when nothing is unresolved", %{conn: conn} do
    editor = authed_user(:editor)
    target = page(editor)

    {:ok, _lv, html} =
      conn |> log_in(editor) |> live(~p"/editor/content/page/#{target.id}")

    refute html =~ "unresolved discussion"
  end

  test "the open panel closes on Escape", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")

    html = render_click(lv, "comment_open", %{"bid" => block_id(ctx.page, 0)})
    assert html =~ ~s(phx-key="Escape")

    html = render_keydown(lv, "comment_close", %{"key" => "Escape"})
    refute html =~ ~s(id="thread-#{block_id(ctx.page, 0)}")
  end
end
