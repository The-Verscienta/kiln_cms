defmodule KilnCMSWeb.PreviewCommentPinsTest do
  @moduledoc """
  Comment markers in the shared/multiplayer preview (#802).

  The three claims the issue asks for: a block with an unresolved thread shows
  a pin, every connected viewer sees it appear live without a reload, and the
  pin links back to the editor with that block's thread open.

  The prerequisite it was blocked on is asserted here too — `render_block/1`
  emitting a stable per-block id — because the pin's position is meaningless
  without something in the DOM to anchor it to.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "pin-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp authed_conn(actor) do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(actor)
  end

  defp signed_in_admin do
    email = "pin-editor-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      name: "Pin Editor",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp a_page(actor) do
    CMS.create_page!(
      %{
        title: "Reviewed Draft",
        slug: "pin-#{System.unique_integer([:positive])}",
        blocks: [
          %{type: :heading, content: "First", data: %{"level" => 2}, order: 0},
          %{type: :quote, content: "Second", order: 1}
        ]
      },
      actor: actor
    )
  end

  # Stored blocks are `%Ash.Union{value: %Kiln.Blocks.*{}}`; the id lives on the
  # typed struct inside.
  defp block_ids(page) do
    page = CMS.get_page!(page.id, authorize?: false)
    Enum.map(page.blocks, & &1.value.id)
  end

  defp eventually(view, substring, present? \\ true, tries \\ 40) do
    html = render(view)

    cond do
      String.contains?(html, substring) == present? -> html
      tries == 0 -> flunk("expected #{substring} #{if present?, do: "in", else: "gone from"}")
      true -> Process.sleep(25) && eventually(view, substring, present?, tries - 1)
    end
  end

  test "render_block/1 anchors every block with its id" do
    actor = admin()
    page = a_page(actor)
    [first, second] = block_ids(page)

    {:ok, view, _html} =
      live(authed_conn(signed_in_admin()), ~p"/editor/preview/page/#{page.id}")

    html = render(view)

    assert html =~ ~s(data-block-id="#{first}")
    assert html =~ ~s(data-block-id="#{second}")
  end

  test "a block with an unresolved thread shows a pin; a clean block does not" do
    actor = signed_in_admin()
    page = a_page(actor)
    [first, second] = block_ids(page)

    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: first, body: "Tighten this"},
      actor: actor
    )

    {:ok, view, _html} = live(authed_conn(actor), ~p"/editor/preview/page/#{page.id}")

    html = render(view)

    assert html =~ "?comment=#{first}"
    refute html =~ "?comment=#{second}"
  end

  test "the pin appears live for a viewer who was already watching" do
    actor = signed_in_admin()
    page = a_page(actor)
    [first, _second] = block_ids(page)

    {:ok, view, _html} = live(authed_conn(actor), ~p"/editor/preview/page/#{page.id}")

    refute render(view) =~ "?comment=#{first}"

    # Added from "elsewhere" — the resource's own action, not this LiveView's
    # event handler, which is the point of broadcasting from the change.
    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: first, body: "Live one"},
      actor: actor
    )

    assert eventually(view, "?comment=#{first}") =~ "?comment=#{first}"
  end

  test "resolving the thread takes its pin away" do
    actor = signed_in_admin()
    page = a_page(actor)
    [first, _second] = block_ids(page)

    comment =
      CMS.add_comment!(
        %{content_type: "page", content_id: page.id, block_id: first, body: "Fix"},
        actor: actor
      )

    {:ok, view, _html} = live(authed_conn(actor), ~p"/editor/preview/page/#{page.id}")
    assert render(view) =~ "?comment=#{first}"

    CMS.resolve_comment!(comment, actor: actor)

    assert eventually(view, "?comment=#{first}", false)
  end

  test "the pin counts the whole thread, not just its root" do
    actor = signed_in_admin()
    page = a_page(actor)
    [first, _second] = block_ids(page)

    for body <- ["One", "Two", "Three"] do
      CMS.add_comment!(
        %{content_type: "page", content_id: page.id, block_id: first, body: body},
        actor: actor
      )
    end

    {:ok, view, _html} = live(authed_conn(actor), ~p"/editor/preview/page/#{page.id}")

    assert render(view) =~ "3 open comments"
  end

  test "the pin's link opens that block's thread in the editor" do
    actor = signed_in_admin()
    page = a_page(actor)
    [first, _second] = block_ids(page)

    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: first, body: "Look here"},
      actor: actor
    )

    {:ok, view, html} =
      live(authed_conn(actor), ~p"/editor/content/page/#{page.id}?comment=#{first}")

    # The editor arrived with that block's panel already open, so the comment
    # body is on the page without anyone clicking.
    assert html =~ "Look here" or render(view) =~ "Look here"
  end
end
