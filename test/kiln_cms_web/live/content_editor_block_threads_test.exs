defmodule KilnCMSWeb.ContentEditorBlockThreadsTest do
  @moduledoc """
  What a block's discussion pin says, and when it changes on its own.

  `KilnCMSWeb.ContentEditorCommentsTest` covers the thread itself — adding,
  threading, resolving. This is the layer above: the state the pin reports at a
  glance, the block tasks it counts, and the live updates that arrive from
  somebody else's window rather than from a click here.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Collab

  @password "password123456"

  defp authed_user(role, name \\ nil) do
    email = "threads-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: name || "#{role}-#{System.unique_integer([:positive])}"
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

  defp page(actor) do
    CMS.create_page!(
      %{
        title: "Threads spec",
        slug: "threads-#{System.unique_integer([:positive])}",
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

  # The pin's state is on the button itself, so a test can assert what an
  # editor sees at a glance without matching on Tailwind classes.
  defp pin_state(html, block_id) do
    case Regex.run(
           ~r/phx-value-bid="#{Regex.escape(block_id)}"[^>]*data-block-discussion="(\w+)"/,
           html,
           capture: :all_but_first
         ) do
      [state] -> state
      nil -> nil
    end
  end

  defp comment(page, block_id, actor, body \\ "Look at this") do
    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: block_id, body: body},
      actor: actor
    )
  end

  defp block_task(page, block_id, actor, attrs \\ %{}) do
    CMS.assign_task!(
      Map.merge(
        %{
          content_type: "page",
          content_id: page.id,
          block_id: block_id,
          assignee_id: actor.id
        },
        attrs
      ),
      actor: actor
    )
  end

  describe "what the pin says" do
    test "a block nobody has said anything about is empty", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {_lv, html} = open_editor(conn, editor, target)

      assert pin_state(html, block_id(target)) == "empty"
    end

    test "an open thread reads unresolved; resolving it settles the pin", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      root = comment(target, block_id(target), editor)
      {lv, html} = open_editor(conn, editor, target)

      assert pin_state(html, block_id(target)) == "unresolved"

      html = render_click(lv, "comment_resolve", %{"id" => root.id})
      assert pin_state(html, block_id(target)) == "resolved"

      html = render_click(lv, "comment_unresolve", %{"id" => root.id})
      assert pin_state(html, block_id(target)) == "unresolved"
    end

    test "an open task with no thread reads tasks", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      block_task(target, block_id(target), editor)
      {_lv, html} = open_editor(conn, editor, target)

      assert pin_state(html, block_id(target)) == "tasks"
    end

    # A block whose only content is a task has no comments to count, so the
    # label must not open with "0 unresolved comments".
    test "a task with no comments is announced without a comment count", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      block_task(target, block_id(target), editor)
      {_lv, html} = open_editor(conn, editor, target)

      assert html =~ ~s(aria-label="1 open task on this block")
      refute html =~ "0 unresolved comment"
    end

    # A block with both is unresolved: the task is work somebody has already
    # accepted, the thread is a decision nobody has made. The task count still
    # renders, so the precedence hides nothing.
    test "a block with both reads unresolved, and still counts the task", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      comment(target, block_id(target), editor)
      block_task(target, block_id(target), editor)
      {_lv, html} = open_editor(conn, editor, target)

      assert pin_state(html, block_id(target)) == "unresolved"
      assert html =~ "1 unresolved comment and 1 open task on this block"
    end

    test "a completed task stops counting", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      task = block_task(target, block_id(target), editor)
      CMS.complete_task!(task, %{}, actor: editor)

      {_lv, html} = open_editor(conn, editor, target)
      assert pin_state(html, block_id(target)) == "empty"
    end

    test "a content-level task belongs to no block's pin", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)

      CMS.assign_task!(
        %{content_type: "page", content_id: target.id, assignee_id: editor.id},
        actor: editor
      )

      {_lv, html} = open_editor(conn, editor, target)

      assert pin_state(html, block_id(target, 0)) == "empty"
      assert pin_state(html, block_id(target, 1)) == "empty"
    end

    test "one block's thread never colours another's pin", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      comment(target, block_id(target, 0), editor)
      {_lv, html} = open_editor(conn, editor, target)

      assert pin_state(html, block_id(target, 0)) == "unresolved"
      assert pin_state(html, block_id(target, 1)) == "empty"
    end
  end

  describe "the open panel" do
    test "lists this block's open tasks with who owes them", %{conn: conn} do
      editor = authed_user(:editor, "Dana Reyes")
      target = page(editor)

      block_task(target, block_id(target), editor, %{due_on: ~D[2026-09-01], note: "Tighten this"})

      {lv, _html} = open_editor(conn, editor, target)
      html = render_click(lv, "comment_open", %{"bid" => block_id(target)})

      assert html =~ "Dana Reyes"
      assert html =~ "Sep 1"
      assert html =~ "Tighten this"
    end

    test "an empty thread invites a mention rather than showing a blank box", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)

      html = render_click(lv, "comment_open", %{"bid" => block_id(target)})
      assert html =~ "Type @ to bring someone in."
    end
  end

  describe "changes made somewhere else" do
    setup %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)
      %{lv: lv, page: target, editor: editor}
    end

    # The point of the broadcast: a thread started in another editor's window
    # (or through the API) moves this pin without anybody touching this
    # session.
    test "a thread started elsewhere lights this pin", ctx do
      require Logger
      assert pin_state(render(ctx.lv), block_id(ctx.page)) == "empty"

      root = comment(ctx.page, block_id(ctx.page), ctx.editor, "From another window")

      Logger.warning(
        "DIAG test created comment id=#{inspect(root.id)} block_id=#{inspect(root.block_id)} " <>
          "org_id=#{inspect(root.org_id)} thread_id=#{inspect(root.thread_id)} " <>
          "resolved_at=#{inspect(root.resolved_at)} page_id=#{inspect(ctx.page.id)} " <>
          "expected_block_id=#{inspect(block_id(ctx.page))} lv_pid=#{inspect(ctx.lv.pid)}"
      )

      # The write already broadcast; this only proves the handler re-reads
      # rather than trusting a payload.
      send(ctx.lv.pid, {:block_thread_changed, block_id(ctx.page)})

      assert pin_state(render(ctx.lv), block_id(ctx.page)) == "unresolved"
    end

    test "a task assigned elsewhere lights this pin", ctx do
      block_task(ctx.page, block_id(ctx.page), ctx.editor)
      send(ctx.lv.pid, {:block_task_changed, block_id(ctx.page)})

      assert pin_state(render(ctx.lv), block_id(ctx.page)) == "tasks"
    end

    test "a coarse block op on the shared topic is ignored, not fatal", ctx do
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        Collab.topic(:page, ctx.page.id),
        {:block_op, %{op: {:remove_block, block_id(ctx.page)}, seq: 1, actor_id: ctx.editor.id}}
      )

      assert render(ctx.lv) =~ "Threads spec"
    end
  end

  describe "typing" do
    setup %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      %{lv: lv, page: target, editor: editor}
    end

    test "a peer typing shows in that block's panel, and ages out", ctx do
      send(ctx.lv.pid, {:typing, Ecto.UUID.generate(), "Sam Okafor", block_id(ctx.page)})
      assert render(ctx.lv) =~ "Sam Okafor is typing…"

      # The expiry the server schedules for itself; delivering it directly
      # keeps the test off the clock.
      send(ctx.lv.pid, {:typing_expired, block_id(ctx.page), "Sam Okafor"})
      refute render(ctx.lv) =~ "is typing"
    end

    test "typing on another block stays on that block", ctx do
      send(ctx.lv.pid, {:typing, Ecto.UUID.generate(), "Sam Okafor", block_id(ctx.page, 1)})

      # The open panel is block 0's, and block 1's panel is closed — so the
      # indicator is nowhere to be seen even though the message arrived.
      refute render(ctx.lv) =~ "Sam Okafor is typing…"
    end

    # Otherwise every author watches themselves type, permanently.
    test "your own typing is not shown back to you", ctx do
      send(ctx.lv.pid, {:typing, ctx.editor.id, "Me", block_id(ctx.page)})
      refute render(ctx.lv) =~ "is typing"
    end

    test "the composer's typing event broadcasts to the document's editors", ctx do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Collab.topic(:page, ctx.page.id))
      render_hook(ctx.lv, "comment_typing", %{"bid" => block_id(ctx.page)})

      actor_id = ctx.editor.id
      block = block_id(ctx.page)
      assert_receive {:typing, ^actor_id, _name, ^block}
    end

    test "a typing event with no block is ignored, not fatal", ctx do
      assert render_hook(ctx.lv, "comment_typing", %{}) =~ "Threads spec"
    end
  end
end
