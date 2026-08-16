defmodule KilnCMS.CMS.TaskBlockTest do
  @moduledoc """
  Block-anchored editorial tasks — the ownership half of inline block
  discussions. `KilnCMS.CMS.TaskTest` covers the content-level shape these
  extend; everything here is about the optional `block_id` narrowing and the
  ways it must *not* change what a `nil`-block task already did.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "task-block-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "task-block-#{System.unique_integer([:positive])}"

  defp drain, do: KilnCMS.DataCase.drain_oban()

  describe "anchoring" do
    test "assign persists a block_id, and omitting it leaves a content-level task" do
      editor = user(:editor)
      assignee = user(:editor)
      content_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      {:ok, on_block} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: content_id,
            block_id: block_id,
            assignee_id: assignee.id,
            note: "This paragraph contradicts the intro"
          },
          actor: editor
        )

      {:ok, on_content} =
        CMS.assign_task(
          %{content_type: "page", content_id: content_id, assignee_id: assignee.id},
          actor: editor
        )

      assert on_block.block_id == block_id
      assert is_nil(on_content.block_id)
      drain()
    end

    test "update re-anchors a content-level task to a block, and can clear it again" do
      editor = user(:editor)
      assignee = user(:editor)
      block_id = Ecto.UUID.generate()

      {:ok, task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: Ecto.UUID.generate(),
            assignee_id: assignee.id
          },
          actor: editor
        )

      assert is_nil(task.block_id)

      {:ok, anchored} = CMS.update_task(task, %{block_id: block_id}, actor: editor)
      assert anchored.block_id == block_id

      # Explicitly back to nil — "this turned out to be a whole-document
      # problem after all" has to be expressible, not a one-way door.
      {:ok, cleared} = CMS.update_task(anchored, %{block_id: nil}, actor: editor)
      assert is_nil(cleared.block_id)
      drain()
    end

    test "an update that doesn't mention block_id leaves the anchor alone" do
      editor = user(:editor)
      assignee = user(:editor)
      block_id = Ecto.UUID.generate()

      {:ok, task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: Ecto.UUID.generate(),
            block_id: block_id,
            assignee_id: assignee.id
          },
          actor: editor
        )

      {:ok, renoted} = CMS.update_task(task, %{note: "Still this block"}, actor: editor)
      assert renoted.block_id == block_id
      drain()
    end
  end

  describe "reads" do
    test "for_block returns only that block's tasks; for_content still returns them all" do
      editor = user(:editor)
      assignee = user(:editor)
      content_id = Ecto.UUID.generate()
      block_a = Ecto.UUID.generate()
      block_b = Ecto.UUID.generate()

      assign = fn attrs ->
        {:ok, task} =
          CMS.assign_task(
            Map.merge(
              %{content_type: "page", content_id: content_id, assignee_id: assignee.id},
              attrs
            ),
            actor: editor
          )

        task
      end

      on_a = assign.(%{block_id: block_a})
      on_b = assign.(%{block_id: block_b})
      on_content = assign.(%{})

      assert [got_a] = CMS.list_tasks_for_block!("page", content_id, block_a, actor: editor)
      assert got_a.id == on_a.id

      all = CMS.list_tasks_for!("page", content_id, actor: editor) |> Enum.map(& &1.id)
      assert on_a.id in all
      assert on_b.id in all
      assert on_content.id in all
      drain()
    end

    test "for_block does not reach across content, even for the same block id" do
      editor = user(:editor)
      assignee = user(:editor)
      block_id = Ecto.UUID.generate()
      mine = Ecto.UUID.generate()
      theirs = Ecto.UUID.generate()

      {:ok, _other} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: theirs,
            block_id: block_id,
            assignee_id: assignee.id
          },
          actor: editor
        )

      assert [] = CMS.list_tasks_for_block!("page", mine, block_id, actor: editor)
      drain()
    end

    test "open_for_content omits completed tasks and keeps content-level ones" do
      editor = user(:editor)
      assignee = user(:editor)
      content_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      {:ok, open_on_block} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: content_id,
            block_id: block_id,
            assignee_id: assignee.id
          },
          actor: editor
        )

      {:ok, open_on_content} =
        CMS.assign_task(
          %{content_type: "page", content_id: content_id, assignee_id: assignee.id},
          actor: editor
        )

      {:ok, to_finish} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: content_id,
            block_id: block_id,
            assignee_id: assignee.id
          },
          actor: editor
        )

      {:ok, _done} = CMS.complete_task(to_finish, %{}, actor: editor)

      ids = CMS.list_open_tasks_for!("page", content_id, actor: editor) |> Enum.map(& &1.id)

      assert open_on_block.id in ids
      assert open_on_content.id in ids
      refute to_finish.id in ids
      drain()
    end
  end

  describe "the rules a block task must keep from a content-level one" do
    test "AssigneeIsEditor still rejects a viewer on a block task" do
      editor = user(:editor)
      viewer = user(:viewer)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.assign_task(
                 %{
                   content_type: "page",
                   content_id: Ecto.UUID.generate(),
                   block_id: Ecto.UUID.generate(),
                   assignee_id: viewer.id
                 },
                 actor: editor
               )

      drain()
    end

    test "viewers cannot create or re-anchor a block task; editors can" do
      editor = user(:editor)
      viewer = user(:viewer)
      assignee = user(:editor)

      attrs = %{
        content_type: "page",
        content_id: Ecto.UUID.generate(),
        block_id: Ecto.UUID.generate(),
        assignee_id: assignee.id
      }

      assert {:error, %Ash.Error.Forbidden{}} = CMS.assign_task(attrs, actor: viewer)
      assert {:ok, task} = CMS.assign_task(attrs, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_task(task, %{block_id: Ecto.UUID.generate()}, actor: viewer)

      drain()
    end

    test "publishing auto-completes block tasks too — publish means the whole document shipped" do
      editor = user(:editor)
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Block auto-complete", slug: slug()}, actor: editor)

      {:ok, task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: page.id,
            block_id: Ecto.UUID.generate(),
            assignee_id: editor.id
          },
          actor: editor
        )

      CMS.publish_page!(page, %{}, actor: admin)
      drain()

      assert CMS.get_task!(task.id, authorize?: false).status == :done
    end

    test "auto_complete_on_publish: false still outlives publish on a block task" do
      editor = user(:editor)
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Block survives publish", slug: slug()}, actor: editor)

      {:ok, task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: page.id,
            block_id: Ecto.UUID.generate(),
            assignee_id: editor.id,
            auto_complete_on_publish: false
          },
          actor: editor
        )

      CMS.publish_page!(page, %{}, actor: admin)
      drain()

      assert CMS.get_task!(task.id, authorize?: false).status == :open
    end
  end

  describe "orphans" do
    test "a task outlives the block it points at, and stays readable both ways" do
      editor = user(:editor)
      block_id = Ecto.UUID.generate()

      page =
        CMS.create_page!(
          %{
            title: "Orphan me",
            slug: slug(),
            blocks: [%{"_type" => "heading", "text" => "Doomed paragraph", "id" => block_id}]
          },
          actor: editor
        )

      {:ok, task} =
        CMS.assign_task(
          %{
            content_type: "page",
            content_id: page.id,
            block_id: block_id,
            assignee_id: editor.id
          },
          actor: editor
        )

      # Deleting a block is an update whose `blocks` list no longer contains
      # it — there is no row to cascade from, which is exactly why the task
      # has to survive on its own rather than being cleaned up by anything.
      _emptied = CMS.update_page!(page, %{blocks: []}, actor: editor)

      assert [still_there] = CMS.list_tasks_for_block!("page", page.id, block_id, actor: editor)
      assert still_there.id == task.id
      assert still_there.status == :open

      assert task.id in (CMS.list_tasks_for!("page", page.id, actor: editor) |> Enum.map(& &1.id))
      drain()
    end
  end
end
