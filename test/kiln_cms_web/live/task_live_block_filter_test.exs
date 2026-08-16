defmodule KilnCMSWeb.TaskLiveBlockFilterTest do
  @moduledoc """
  The workload view's block column and anchor filter: which block a task names,
  what a removed block looks like, and what each filter chip scopes to.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, name) do
    email = "tasklive-#{System.unique_integer([:positive])}@example.com"

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

  defp page(actor, title) do
    CMS.create_page!(
      %{
        title: title,
        slug: "tasklive-#{System.unique_integer([:positive])}",
        blocks: [
          %{"_type" => "quote", "text" => "Quoted"},
          %{"_type" => "heading", "text" => "Headed"}
        ]
      },
      actor: actor
    )
  end

  defp block_id(page, index \\ 0),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp assign_task(page, actor, attrs \\ %{}) do
    CMS.assign_task!(
      Map.merge(
        %{content_type: "page", content_id: page.id, assignee_id: actor.id},
        attrs
      ),
      actor: actor
    )
  end

  setup %{conn: conn} do
    editor = authed_user(:editor, "Rowan Vance")
    %{conn: log_in(conn, editor), editor: editor}
  end

  describe "the block column" do
    test "a block task names its block type and links onto its discussion", ctx do
      target = page(ctx.editor, "Column spec")
      assign_task(target, ctx.editor, %{block_id: block_id(target, 0)})

      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks")

      assert html =~ "quote"

      assert html =~
               "/editor/content/page/#{target.id}?comment=#{block_id(target, 0)}"
    end

    test "a document-level task names no block at all", ctx do
      target = page(ctx.editor, "No block spec")
      assign_task(target, ctx.editor)

      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks")

      assert html =~ "No block spec"
      refute html =~ "removed block"
      refute html =~ "?comment="
    end

    # Nothing cascades when a block is deleted, so the task is still real and
    # still somebody's — a row that quietly stopped mentioning its block would
    # read as whole-document work.
    test "a task whose block was deleted says so rather than going quiet", ctx do
      target = page(ctx.editor, "Orphan spec")
      doomed = block_id(target, 0)
      assign_task(target, ctx.editor, %{block_id: doomed})

      CMS.update_page!(
        target,
        %{blocks: [%{"_type" => "heading", "text" => "Headed"}]},
        actor: ctx.editor
      )

      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks")

      assert html =~ "removed block"
      refute html =~ "?comment=#{doomed}"
    end
  end

  describe "the anchor filter" do
    setup ctx do
      target = page(ctx.editor, "Filter spec")

      %{
        page: target,
        on_block:
          assign_task(target, ctx.editor, %{block_id: block_id(target, 0), note: "Blocky"}),
        on_document: assign_task(target, ctx.editor, %{note: "Documenty"})
      }
    end

    test "all is the default and hides nothing", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks")

      assert html =~ "Blocky"
      assert html =~ "Documenty"
    end

    test "a block scopes to block-anchored tasks", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks?scope=block")

      assert html =~ "Blocky"
      refute html =~ "Documenty"
    end

    test "the whole document scopes to the rest", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks?scope=document")

      refute html =~ "Blocky"
      assert html =~ "Documenty"
    end

    test "the filter holds across the team view", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks?view=team&scope=block")

      assert html =~ "Blocky"
      refute html =~ "Documenty"
    end

    test "an unknown scope falls back to all rather than to nothing", ctx do
      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/tasks?scope=nonsense")

      assert html =~ "Blocky"
      assert html =~ "Documenty"
    end
  end

  describe "the overview's counts" do
    test "count blocks needing attention and block-anchored work", ctx do
      target = page(ctx.editor, "Overview spec")

      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: block_id(target, 0),
          body: "Open question"
        },
        actor: ctx.editor
      )

      # A reply is not a second thread, and a resolved one is not a pending
      # question — neither should move the count.
      CMS.add_comment!(
        %{
          content_type: "page",
          content_id: target.id,
          block_id: block_id(target, 0),
          body: "Replying"
        },
        actor: ctx.editor
      )

      settled =
        CMS.add_comment!(
          %{
            content_type: "page",
            content_id: target.id,
            block_id: block_id(target, 1),
            body: "Settled question"
          },
          actor: ctx.editor
        )

      CMS.resolve_comment!(settled, %{}, actor: ctx.editor)

      assign_task(target, ctx.editor, %{block_id: block_id(target, 0)})

      {:ok, _lv, html} = live(ctx.conn, ~p"/editor/overview")

      assert html =~ "1 block with an unresolved discussion"
      assert html =~ "1 open task anchored to a block"
      assert html =~ "/editor/tasks?view=team&amp;scope=block"
    end
  end
end
