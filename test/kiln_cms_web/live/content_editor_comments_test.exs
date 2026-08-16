defmodule KilnCMSWeb.ContentEditorCommentsTest do
  @moduledoc """
  Block-level editorial comments in the content editor (#404): the per-block
  panel, adding a comment, threading a reply, and resolve/unresolve.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "comments-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: "#{role}-#{System.unique_integer([:positive])}"
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

  # Two blocks, deliberately — one with a comment thread, one without, so a
  # cross-block leak isn't masked by there being only one to look at.
  defp two_blocks do
    [
      %{"_type" => "quote", "text" => "First block"},
      %{"_type" => "quote", "text" => "Second block"}
    ]
  end

  defp page(actor, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Comments spec",
          slug: "comments-#{System.unique_integer([:positive])}",
          blocks: two_blocks()
        },
        attrs
      ),
      actor: actor
    )
  end

  defp block_id(page, index \\ 0),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp open_panel(lv, page, index \\ 0) do
    render_click(lv, "comment_open", %{"bid" => block_id(page, index)})
  end

  defp write(lv, body) do
    render_change(lv, "comment_draft", %{"comment_body" => body})
  end

  defp send_comment(lv, page, index \\ 0) do
    render_click(lv, "comment_add", %{"bid" => block_id(page, index)})
  end

  describe "the panel" do
    test "shows a plain 'Comment' control when the block has none", %{conn: conn} do
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Comment"
      refute html =~ "Resolved"
    end

    test "opening a block's panel shows it as expanded", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)

      html = open_panel(lv, target)
      assert html =~ ~s(phx-value-bid="#{block_id(target)}" aria-expanded="true")
    end
  end

  describe "adding a comment" do
    setup %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)
      %{lv: lv, page: target, editor: editor}
    end

    test "appears in the panel and updates the count on the toggle button", ctx do
      open_panel(ctx.lv, ctx.page)
      write(ctx.lv, "Please cite a source here")
      html = send_comment(ctx.lv, ctx.page)

      assert html =~ "Please cite a source here"
      assert html =~ "1 comment"

      [comment] = CMS.list_comments_for!("page", ctx.page.id, actor: ctx.editor)
      assert comment.body == "Please cite a source here"
      assert comment.author_id == ctx.editor.id
      assert is_nil(comment.thread_id)
    end

    test "a blank draft is not sent", ctx do
      open_panel(ctx.lv, ctx.page)
      write(ctx.lv, "   ")
      send_comment(ctx.lv, ctx.page)

      assert CMS.list_comments_for!("page", ctx.page.id, actor: ctx.editor) == []
    end

    test "a second comment on the same block replies into the first's thread", ctx do
      open_panel(ctx.lv, ctx.page)
      write(ctx.lv, "First")
      send_comment(ctx.lv, ctx.page)
      write(ctx.lv, "Second")
      html = send_comment(ctx.lv, ctx.page)

      assert html =~ "2 comments"

      [root, reply] = CMS.list_comments_for!("page", ctx.page.id, actor: ctx.editor)
      assert is_nil(root.thread_id)
      assert reply.thread_id == root.id
    end

    test "a comment on one block never shows up under another", ctx do
      open_panel(ctx.lv, ctx.page, 0)
      write(ctx.lv, "On the first block")
      send_comment(ctx.lv, ctx.page, 0)

      html = open_panel(ctx.lv, ctx.page, 1)

      refute html =~ "On the first block"
      assert html =~ "No comments on this block yet."
    end

    test "opening a different block's panel closes the previous one", ctx do
      open_panel(ctx.lv, ctx.page, 0)
      html = open_panel(ctx.lv, ctx.page, 1)

      assert html =~ "No comments on this block yet."
      refute html =~ ~s(phx-value-bid="#{block_id(ctx.page, 0)}" aria-expanded="true")
    end

    test "events missing their params are ignored, not fatal", ctx do
      for event <- ~w(comment_open comment_add) do
        assert render_click(ctx.lv, event, %{}) =~ "Comment"
      end
    end
  end

  describe "resolving" do
    setup %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)
      open_panel(lv, target)
      write(lv, "Needs a citation")
      send_comment(lv, target)
      %{lv: lv, page: target, editor: editor}
    end

    test "marks the thread resolved and offers to reopen it", ctx do
      [root] = CMS.list_comments_for!("page", ctx.page.id, actor: ctx.editor)
      html = render_click(ctx.lv, "comment_resolve", %{"id" => root.id})

      assert html =~ "Resolved"
      assert html =~ "Reopen thread"

      reloaded = CMS.get_comment!(root.id, authorize?: false)
      refute is_nil(reloaded.resolved_at)
      assert reloaded.resolved_by_id == ctx.editor.id
    end

    test "unresolving clears it again", ctx do
      [root] = CMS.list_comments_for!("page", ctx.page.id, actor: ctx.editor)
      render_click(ctx.lv, "comment_resolve", %{"id" => root.id})
      html = render_click(ctx.lv, "comment_unresolve", %{"id" => root.id})

      refute html =~ "Resolved"

      reloaded = CMS.get_comment!(root.id, authorize?: false)
      assert is_nil(reloaded.resolved_at)
    end

    test "a reply's id cannot be resolved directly", ctx do
      write(ctx.lv, "A reply")
      send_comment(ctx.lv, ctx.page)

      [root, reply] = CMS.list_comments_for!("page", ctx.page.id, actor: ctx.editor)
      html = render_click(ctx.lv, "comment_resolve", %{"id" => reply.id})

      refute html =~ "Resolved"
      assert is_nil(CMS.get_comment!(root.id, authorize?: false).resolved_at)
    end

    test "an unknown id is ignored rather than crashing the editor", ctx do
      html = render_click(ctx.lv, "comment_resolve", %{"id" => Ecto.UUID.generate()})

      assert html =~ "Needs a citation"
    end
  end

  describe "document-level comments (#946)" do
    test "an automation-authored, block-less comment shows in Document notes as 'Automation'",
         %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)

      {:ok, doc_comment} =
        CMS.add_comment(
          %{
            content_type: "page",
            content_id: target.id,
            block_id: nil,
            body: "Possible duplicates of this document were found.",
            created_by_rule_id: Ecto.UUID.generate()
          },
          actor: nil,
          authorize?: false
        )

      {lv, html} = open_editor(conn, editor, target)

      assert html =~ "Document notes"
      assert html =~ "Possible duplicates of this document were found."
      assert html =~ "Automation"
      refute html =~ "No document-level comments."

      # It does not leak into either block's own thread panel — each still
      # reports zero comments of its own when opened.
      assert open_panel(lv, target, 0) =~ "No comments on this block yet."
      assert open_panel(lv, target, 1) =~ "No comments on this block yet."

      refute is_nil(doc_comment.id)
    end

    test "with no document-level comments, the panel says so", %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)

      {_lv, html} = open_editor(conn, editor, target)

      assert html =~ "No document-level comments."
    end
  end

  # #1252 review: the editor subscribes to `PreviewLive.topic(kind, id)` (the
  # same topic `:preview_comments_changed` above arrives on) so it can pick up
  # a document-level comment written elsewhere — but `PreviewLive` also
  # broadcasts `{:preview_switch, id}` on that exact topic when a pop-out
  # preview switches locale variant, which the editor had no `handle_info`
  # clause for and no catch-all, crashing the LiveView.
  test "a preview variant switch on the same topic does not crash the editor", %{conn: conn} do
    editor = authed_user(:editor)
    target = page(editor)

    {lv, _html} = open_editor(conn, editor, target)

    send(lv.pid, {:preview_switch, target.id})

    # The process is still alive and rendering normally — a crash would have
    # made every subsequent render/event call in this test raise.
    assert render(lv) =~ target.title
  end

  test "a viewer sees the editor gate, not the comment controls", %{conn: conn} do
    viewer = authed_user(:viewer)
    target = page(authed_user(:editor))

    assert {:error, {:redirect, _}} =
             conn |> log_in(viewer) |> live(~p"/editor/content/page/#{target.id}")
  end
end
