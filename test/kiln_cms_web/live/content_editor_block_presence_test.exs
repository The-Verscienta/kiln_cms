defmodule KilnCMSWeb.ContentEditorBlockPresenceTest do
  @moduledoc """
  Who is on which block.

  Block focus rides the existing `editing:<kind>:<id>` Presence meta rather
  than a topic per block, so what these tests check is that the meta moves,
  that peers see it, and that it clears — never that a message was sent.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.Presence

  @password "password123456"

  defp authed_user(role, name) do
    email = "bpresence-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: name
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
        title: "Presence spec",
        slug: "bpresence-#{System.unique_integer([:positive])}",
        blocks: [
          %{"_type" => "quote", "text" => "First block"},
          %{"_type" => "quote", "text" => "Second block"}
        ]
      },
      actor: actor
    )
  end

  defp block_id(page, index \\ 0),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp open_editor(conn, user, page) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    lv
  end

  defp where_is(page, user) do
    "page"
    |> Presence.editors(page.id)
    |> Enum.find(&(&1.id == user.id))
    |> case do
      nil -> :absent
      editor -> editor.block_id
    end
  end

  setup %{conn: conn} do
    editor = authed_user(:editor, "Rae Lindqvist")
    target = page(editor)
    %{lv: open_editor(conn, editor, target), page: target, editor: editor}
  end

  test "an editor starts on the document, not on any block", ctx do
    assert where_is(ctx.page, ctx.editor) == nil
  end

  test "focusing a block records it; focusing another moves it", ctx do
    render_hook(ctx.lv, "presence_focus", %{"bid" => block_id(ctx.page, 0)})
    assert where_is(ctx.page, ctx.editor) == block_id(ctx.page, 0)

    render_hook(ctx.lv, "presence_focus", %{"bid" => block_id(ctx.page, 1)})
    assert where_is(ctx.page, ctx.editor) == block_id(ctx.page, 1)
  end

  test "blurring clears it without dropping the editor from the document", ctx do
    render_hook(ctx.lv, "presence_focus", %{"bid" => block_id(ctx.page)})
    render_hook(ctx.lv, "presence_focus", %{"bid" => nil})

    assert where_is(ctx.page, ctx.editor) == nil
    refute where_is(ctx.page, ctx.editor) == :absent
  end

  test "an empty block id is treated as a blur, not as a block called \"\"", ctx do
    render_hook(ctx.lv, "presence_focus", %{"bid" => block_id(ctx.page)})
    render_hook(ctx.lv, "presence_focus", %{"bid" => ""})

    assert where_is(ctx.page, ctx.editor) == nil
  end

  test "a malformed focus event is ignored, not fatal", ctx do
    assert render_hook(ctx.lv, "presence_focus", %{}) =~ "Presence spec"
  end

  describe "two editors" do
    setup %{conn: conn, page: target} do
      peer = authed_user(:editor, "Nadia Osei")
      %{peer: peer, peer_lv: open_editor(conn, peer, target)}
    end

    test "each sees where the other is, and not their own avatar", ctx do
      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page)})

      # The diff reaches the first editor's LiveView, which re-reads the roster.
      html = render(ctx.lv)

      assert html =~ "Nadia Osei is on this block"
      refute html =~ "Rae Lindqvist is on this block"
    end

    test "the avatar follows the peer from one block to the other", ctx do
      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page, 0)})
      assert where_is(ctx.page, ctx.peer) == block_id(ctx.page, 0)

      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page, 1)})
      assert where_is(ctx.page, ctx.peer) == block_id(ctx.page, 1)

      # Still exactly one avatar on the page, not one left behind on block 0.
      html = render(ctx.lv)
      assert length(String.split(html, "Nadia Osei is on this block")) == 2
    end

    test "a peer leaving takes their avatar with them", ctx do
      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page)})
      assert render(ctx.lv) =~ "Nadia Osei is on this block"

      GenServer.stop(ctx.peer_lv.pid)
      # One render to let the presence_diff land, one to read the result.
      render(ctx.lv)

      assert where_is(ctx.page, ctx.peer) == :absent
      refute render(ctx.lv) =~ "Nadia Osei is on this block"
    end
  end
end
