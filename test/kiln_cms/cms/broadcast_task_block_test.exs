defmodule KilnCMS.CMS.BroadcastTaskBlockTest do
  @moduledoc """
  `KilnCMS.CMS.Changes.BroadcastTaskBlock` — the PubSub half of block-anchored
  tasks. What matters here is not that a message is sent but *which* block ids
  it names: a gutter count that moves on one block and not the other is the
  whole point of re-anchoring emitting two.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Collab

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bcast-task-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  # The editor subscribes with its `kind` atom; the resource broadcasts from
  # the string it stores. Subscribing the atom way here is what proves the two
  # actually meet on one topic.
  defp subscribe(content_id),
    do: Phoenix.PubSub.subscribe(KilnCMS.PubSub, Collab.topic(:page, content_id))

  test "assigning a block task announces that block" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()
    :ok = subscribe(content_id)

    {:ok, _task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: block_id,
          assignee_id: editor.id
        },
        actor: editor
      )

    assert_receive {:block_task_changed, ^block_id}, 2_000
    drain()
  end

  test "a content-level task announces nil — the document's task list still changed" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    :ok = subscribe(content_id)

    {:ok, _task} =
      CMS.assign_task(
        %{content_type: "page", content_id: content_id, assignee_id: editor.id},
        actor: editor
      )

    assert_receive {:block_task_changed, nil}, 2_000
    drain()
  end

  test "a create announces exactly one block — never its own nil `data` as well" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()
    :ok = subscribe(content_id)

    {:ok, _task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: block_id,
          assignee_id: editor.id
        },
        actor: editor
      )

    assert_receive {:block_task_changed, ^block_id}, 2_000
    refute_receive {:block_task_changed, nil}
    drain()
  end

  test "re-anchoring announces both blocks, so the old pin loses its count" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    from_block = Ecto.UUID.generate()
    to_block = Ecto.UUID.generate()

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: from_block,
          assignee_id: editor.id
        },
        actor: editor
      )

    :ok = subscribe(content_id)

    {:ok, _moved} = CMS.update_task(task, %{block_id: to_block}, actor: editor)

    assert_receive {:block_task_changed, ^to_block}, 2_000
    assert_receive {:block_task_changed, ^from_block}, 2_000
    drain()
  end

  test "an update that leaves the anchor alone announces it once, not twice" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: block_id,
          assignee_id: editor.id
        },
        actor: editor
      )

    :ok = subscribe(content_id)

    {:ok, _renoted} = CMS.update_task(task, %{note: "Same block"}, actor: editor)

    assert_receive {:block_task_changed, ^block_id}, 2_000
    refute_receive {:block_task_changed, ^block_id}
    drain()
  end

  test "completing and reopening both announce the block" do
    editor = user(:editor)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id,
          block_id: block_id,
          assignee_id: editor.id
        },
        actor: editor
      )

    :ok = subscribe(content_id)

    {:ok, done} = CMS.complete_task(task, %{}, actor: editor)
    assert_receive {:block_task_changed, ^block_id}, 2_000

    {:ok, _reopened} = CMS.reopen_task(done, %{}, actor: editor)
    assert_receive {:block_task_changed, ^block_id}, 2_000
    drain()
  end

  test "a rejected write announces nothing — no pin for a task that did not save" do
    editor = user(:editor)
    viewer = user(:viewer)
    content_id = Ecto.UUID.generate()
    block_id = Ecto.UUID.generate()
    :ok = subscribe(content_id)

    assert {:error, _} =
             CMS.assign_task(
               %{
                 content_type: "page",
                 content_id: content_id,
                 block_id: block_id,
                 assignee_id: viewer.id
               },
               actor: editor
             )

    refute_receive {:block_task_changed, _}
    drain()
  end

  test "the announcement is scoped to its own document" do
    editor = user(:editor)
    mine = Ecto.UUID.generate()
    theirs = Ecto.UUID.generate()
    :ok = subscribe(mine)

    {:ok, _task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: theirs,
          block_id: Ecto.UUID.generate(),
          assignee_id: editor.id
        },
        actor: editor
      )

    refute_receive {:block_task_changed, _}
    drain()
  end
end
