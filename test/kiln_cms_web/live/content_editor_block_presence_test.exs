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

  @peer_on_block "Nadia Osei is on this block"
  @self_on_block "Rae Lindqvist is on this block"

  # Every assertion about what the OTHER editor sees crosses a process
  # boundary: the peer updates its own Presence meta, `Phoenix.Tracker`
  # broadcasts a `presence_diff`, and this LiveView handles it and re-renders.
  # `render_hook/3` returns once the PEER has handled the event, and
  # `GenServer.stop/1` once the peer's process is gone — neither waits for any
  # of that. Reading once therefore pins a *schedule* ("one render is always
  # enough"), which is stricter than the behaviour worth asserting: that the
  # avatar arrives, and goes.
  #
  # "a peer leaving takes their avatar with them" failed on its FIRST assertion
  # under a full-suite run — the one that sets the scene, not the one the test
  # is named for. Waiting for the condition rather than assuming it costs
  # nothing when it has already landed, and a state that never resolves still
  # fails, through the caller's own assertion with its HTML attached, one
  # second later.
  defp settle(condition, attempts \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts <= 1 ->
        :ok

      true ->
        Process.sleep(10)
        settle(condition, attempts - 1)
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
      settle(fn -> render(ctx.lv) =~ @peer_on_block end)
      html = render(ctx.lv)

      assert html =~ @peer_on_block
      refute html =~ @self_on_block
    end

    test "the avatar follows the peer from one block to the other", ctx do
      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page, 0)})
      assert where_is(ctx.page, ctx.peer) == block_id(ctx.page, 0)

      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page, 1)})
      assert where_is(ctx.page, ctx.peer) == block_id(ctx.page, 1)

      # Still exactly one avatar on the page, not one left behind on block 0.
      settle(fn -> length(String.split(render(ctx.lv), @peer_on_block)) == 2 end)
      html = render(ctx.lv)
      assert length(String.split(html, @peer_on_block)) == 2
    end

    test "a peer leaving takes their avatar with them", ctx do
      render_hook(ctx.peer_lv, "presence_focus", %{"bid" => block_id(ctx.page)})

      settle(fn -> render(ctx.lv) =~ @peer_on_block end)
      assert render(ctx.lv) =~ @peer_on_block

      GenServer.stop(ctx.peer_lv.pid)

      # The entry goes when the tracker sees the peer's process die, which is
      # its own hop after `stop/1` returns — so this waits too, rather than
      # spending a render as a sleep and hoping (the previous shape).
      settle(fn -> where_is(ctx.page, ctx.peer) == :absent end)
      assert where_is(ctx.page, ctx.peer) == :absent

      settle(fn -> not (render(ctx.lv) =~ @peer_on_block) end)
      refute render(ctx.lv) =~ @peer_on_block
    end
  end
end
