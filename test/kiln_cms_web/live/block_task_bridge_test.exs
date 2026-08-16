defmodule KilnCMSWeb.BlockTaskBridgeTest do
  @moduledoc """
  Turning a block's discussion into accountable work: the seeded "Create task"
  form, "Link existing" re-anchoring, and what happens to both when the block
  they name is deleted.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, name) do
    email = "bridge-#{System.unique_integer([:positive])}@example.com"

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
        title: "Bridge spec",
        slug: "bridge-#{System.unique_integer([:positive])}",
        blocks: [
          %{"_type" => "quote", "text" => "First block"},
          %{"_type" => "heading", "text" => "Second block"}
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

  defp surname, do: "Q#{System.unique_integer([:positive])}"

  defp comment(page, block_id, actor, body) do
    CMS.add_comment!(
      %{content_type: "page", content_id: page.id, block_id: block_id, body: body},
      actor: actor
    )
  end

  defp tasks_for(page, actor), do: CMS.list_tasks_for!("page", page.id, actor: actor)

  describe "creating a task from a thread" do
    setup %{conn: conn} do
      editor = authed_user(:editor, "Opener #{surname()}")
      %{conn: conn, editor: editor}
    end

    test "seeds the note from the root comment and a due date a week out", ctx do
      target = page(ctx.editor)
      comment(target, block_id(target), ctx.editor, "This paragraph contradicts the intro")

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      html = render_click(lv, "block_task_open", %{"bid" => block_id(target)})

      assert html =~ "This paragraph contradicts the intro"
      assert html =~ Date.to_iso8601(Date.add(Date.utc_today(), 7))
    end

    # The seed comes from `Mentions.resolve/2` — the same call that decides who
    # was emailed about the comment — so the person told about it is the person
    # offered the work.
    test "seeds the assignee from the root comment's first resolvable mention", ctx do
      family = surname()
      ben = authed_user(:editor, "Ben #{family}")
      target = page(ctx.editor)
      comment(target, block_id(target), ctx.editor, "@ben#{String.downcase(family)} can you fix?")

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      html = render_click(lv, "block_task_open", %{"bid" => block_id(target)})

      assert html =~ ~s(value="#{ben.id}" selected)
    end

    # Ambiguity notifies nobody, so it must seed nobody too — offering one of
    # two Bens would be the guess the resolver refuses to make.
    test "an ambiguous mention seeds no assignee", ctx do
      authed_user(:editor, "Ben #{surname()}")
      authed_user(:editor, "Ben #{surname()}")
      target = page(ctx.editor)
      comment(target, block_id(target), ctx.editor, "@ben please fix")

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      html = render_click(lv, "block_task_open", %{"bid" => block_id(target)})

      refute html =~ ~s( selected>Ben )
    end

    # A viewer cannot hold a task (`AssigneeIsEditor`), so mentioning one must
    # not seed a form that will be rejected on submit.
    test "a mentioned viewer is not seeded as the assignee", ctx do
      family = surname()
      authed_user(:viewer, "Vee #{family}")
      target = page(ctx.editor)
      comment(target, block_id(target), ctx.editor, "@vee#{String.downcase(family)} thoughts?")

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      html = render_click(lv, "block_task_open", %{"bid" => block_id(target)})

      refute html =~ "Vee #{family}"
    end

    test "assigning persists the block and shows up on that block's pin", ctx do
      target = page(ctx.editor)
      comment(target, block_id(target), ctx.editor, "Needs a source")

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      render_click(lv, "block_task_open", %{"bid" => block_id(target)})
      render_change(lv, "block_task_draft", %{"task_assignee_id" => ctx.editor.id})
      html = render_click(lv, "block_task_submit", %{"bid" => block_id(target)})

      assert [task] = tasks_for(target, ctx.editor)
      assert task.block_id == block_id(target)
      assert task.assignee_id == ctx.editor.id
      assert task.due_on == Date.add(Date.utc_today(), 7)
      assert task.note == "Needs a source"
      # `nil` = follow the site setting, which is the blank option's meaning.
      assert is_nil(task.auto_complete_on_publish)

      assert html =~ "Task created on this block."
    end

    test "the per-task publish override survives the form", ctx do
      target = page(ctx.editor)

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      render_click(lv, "block_task_open", %{"bid" => block_id(target)})
      render_change(lv, "block_task_draft", %{"task_assignee_id" => ctx.editor.id})
      render_change(lv, "block_task_draft", %{"task_auto_complete" => "false"})
      render_click(lv, "block_task_submit", %{"bid" => block_id(target)})

      assert [task] = tasks_for(target, ctx.editor)
      assert task.auto_complete_on_publish == false
    end

    test "an assignment with no assignee fails without closing the form", ctx do
      target = page(ctx.editor)

      lv = open_editor(ctx.conn, ctx.editor, target)
      render_click(lv, "comment_open", %{"bid" => block_id(target)})
      render_click(lv, "block_task_open", %{"bid" => block_id(target)})
      html = render_click(lv, "block_task_submit", %{"bid" => block_id(target)})

      assert tasks_for(target, ctx.editor) == []
      assert html =~ "Couldn&#39;t assign that task."
    end

    test "events missing their params are ignored, not fatal", ctx do
      target = page(ctx.editor)
      lv = open_editor(ctx.conn, ctx.editor, target)

      for event <- ~w(block_task_open block_task_submit block_task_link) do
        assert render_click(lv, event, %{}) =~ "Bridge spec"
      end

      assert render_change(lv, "block_task_draft", %{}) =~ "Bridge spec"
    end
  end

  describe "linking an existing task" do
    setup %{conn: conn} do
      editor = authed_user(:editor, "Linker #{surname()}")
      target = page(editor)
      %{conn: conn, editor: editor, page: target}
    end

    test "re-anchors a document-level task onto the block", ctx do
      task =
        CMS.assign_task!(
          %{content_type: "page", content_id: ctx.page.id, assignee_id: ctx.editor.id},
          actor: ctx.editor
        )

      lv = open_editor(ctx.conn, ctx.editor, ctx.page)
      render_click(lv, "comment_open", %{"bid" => block_id(ctx.page)})
      html = render_change(lv, "block_task_link", %{"link_task_id" => task.id})

      assert CMS.get_task!(task.id, authorize?: false).block_id == block_id(ctx.page)
      assert html =~ "Task moved to this block."
    end

    # Offering one would silently empty the other block's pin, which is not
    # what "link this task here" sounds like it does.
    test "a task already anchored elsewhere is neither offered nor movable", ctx do
      other =
        CMS.assign_task!(
          %{
            content_type: "page",
            content_id: ctx.page.id,
            block_id: block_id(ctx.page, 1),
            assignee_id: ctx.editor.id
          },
          actor: ctx.editor
        )

      lv = open_editor(ctx.conn, ctx.editor, ctx.page)
      html = render_click(lv, "comment_open", %{"bid" => block_id(ctx.page, 0)})

      refute html =~ ~s(value="#{other.id}")

      render_change(lv, "block_task_link", %{"link_task_id" => other.id})
      assert CMS.get_task!(other.id, authorize?: false).block_id == block_id(ctx.page, 1)
    end

    test "an unknown task id is ignored rather than crashing the editor", ctx do
      lv = open_editor(ctx.conn, ctx.editor, ctx.page)
      render_click(lv, "comment_open", %{"bid" => block_id(ctx.page)})

      assert render_change(lv, "block_task_link", %{"link_task_id" => Ecto.UUID.generate()}) =~
               "Bridge spec"
    end
  end

  describe "when the block is deleted" do
    test "its thread and tasks are still rendered, under a banner", %{conn: conn} do
      editor = authed_user(:editor, "Orphan #{surname()}")
      target = page(editor)
      doomed = block_id(target, 0)

      comment(target, doomed, editor, "About the doomed block")

      CMS.assign_task!(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: doomed,
          assignee_id: editor.id
        },
        actor: editor
      )

      # Deleting a block is an update whose `blocks` list no longer holds it.
      emptied =
        CMS.update_page!(
          target,
          %{blocks: [%{"_type" => "heading", "text" => "Second block"}]},
          actor: editor
        )

      lv = open_editor(conn, editor, emptied)
      html = render(lv)

      assert html =~ "Discussions on removed blocks"

      # And it is still openable — the point of keeping it is being able to
      # close it out. The per-thread banner lives inside the panel, next to
      # the discussion it explains.
      html = render_click(lv, "comment_open", %{"bid" => doomed})
      assert html =~ "About the doomed block"
      assert html =~ "This block was removed. The discussion and its tasks are kept."
    end

    test "a document with no orphans shows no such section", %{conn: conn} do
      editor = authed_user(:editor, "Tidy #{surname()}")
      target = page(editor)
      comment(target, block_id(target), editor, "Still here")

      html = render(open_editor(conn, editor, target))

      refute html =~ "Discussions on removed blocks"
    end
  end
end
