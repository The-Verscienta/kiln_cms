defmodule KilnCMS.CMS.TaskTest do
  @moduledoc """
  Editorial tasks (#501): assignment, completion, the read shapes the
  calendar/digest/workload views depend on, and the auto-complete-on-publish
  hook (`KilnCMS.CMS.Changes.AutoCompleteTasks`).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "task-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "task-#{System.unique_integer([:positive])}"

  defp drain, do: KilnCMS.DataCase.drain_oban()

  test "assigning a task stamps the creator and defaults to open" do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: ~D[2026-09-01],
          note: "Please review the intro"
        },
        actor: editor
      )

    assert task.creator_id == editor.id
    assert task.assignee_id == assignee.id
    assert task.status == :open
    drain()
  end

  test "a task cannot be assigned to a viewer, or reassigned to one (#501 security review)" do
    editor = user(:editor)
    viewer = user(:viewer)
    assignee = user(:editor)

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.assign_task(
               %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: viewer.id},
               actor: editor
             )

    {:ok, task} =
      CMS.assign_task(
        %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id},
        actor: editor
      )

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.update_task(task, %{assignee_id: viewer.id}, actor: editor)

    drain()
  end

  test "editors may assign; viewers may not" do
    editor = user(:editor)
    viewer = user(:viewer)
    assignee = user(:editor)

    attrs = %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id}

    assert {:ok, _} = CMS.assign_task(attrs, actor: editor)
    assert {:error, %Ash.Error.Forbidden{}} = CMS.assign_task(attrs, actor: viewer)
    drain()
  end

  test "completing a task stamps who and when; reopening clears both" do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, task} =
      CMS.assign_task(
        %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id},
        actor: editor
      )

    {:ok, done} = CMS.complete_task(task, %{}, actor: editor)
    assert done.status == :done
    assert done.completed_by_id == editor.id
    refute is_nil(done.completed_at)

    {:ok, reopened} = CMS.reopen_task(done, %{}, actor: editor)
    assert reopened.status == :open
    assert is_nil(reopened.completed_at)
    assert is_nil(reopened.completed_by_id)
    drain()
  end

  test "for_assignee lists only the assignee's OPEN tasks, due-date ascending" do
    editor = user(:editor)
    assignee = user(:editor)
    other = user(:editor)
    content_id = fn -> Ecto.UUID.generate() end

    {:ok, later} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id.(),
          assignee_id: assignee.id,
          due_on: ~D[2026-12-01]
        },
        actor: editor
      )

    {:ok, sooner} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id.(),
          assignee_id: assignee.id,
          due_on: ~D[2026-10-01]
        },
        actor: editor
      )

    {:ok, done} =
      CMS.assign_task(
        %{content_type: "page", content_id: content_id.(), assignee_id: assignee.id},
        actor: editor
      )

    {:ok, _} = CMS.complete_task(done, %{}, actor: editor)

    {:ok, _} =
      CMS.assign_task(
        %{content_type: "page", content_id: content_id.(), assignee_id: other.id},
        actor: editor
      )

    assert [got_sooner, got_later] = CMS.list_tasks_for_assignee!(assignee.id, actor: editor)
    assert got_sooner.id == sooner.id
    assert got_later.id == later.id
    drain()
  end

  test "open_due_between is a window over open tasks; due_within has no lower bound" do
    editor = user(:editor)
    assignee = user(:editor)
    content_id = fn -> Ecto.UUID.generate() end

    {:ok, overdue} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id.(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), -10)
        },
        actor: editor
      )

    {:ok, soon} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id.(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), 2)
        },
        actor: editor
      )

    {:ok, far} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: content_id.(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), 60)
        },
        actor: editor
      )

    within =
      CMS.list_tasks_due_within!(Date.add(Date.utc_today(), 3), actor: editor)
      |> Enum.map(& &1.id)

    assert overdue.id in within
    assert soon.id in within
    refute far.id in within

    window =
      CMS.list_tasks_open_due_between!(Date.utc_today(), Date.add(Date.utc_today(), 3),
        actor: editor
      )
      |> Enum.map(& &1.id)

    refute overdue.id in window
    assert soon.id in window
    refute far.id in window

    drain()
  end

  test "publishing content auto-completes its open tasks" do
    editor = user(:editor)
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Auto-complete me", slug: slug()}, actor: editor)

    {:ok, task} =
      CMS.assign_task(
        %{content_type: "page", content_id: page.id, assignee_id: editor.id},
        actor: editor
      )

    CMS.publish_page!(page, %{}, actor: admin)
    drain()

    completed = CMS.get_task!(task.id, authorize?: false)
    assert completed.status == :done
    assert is_nil(completed.completed_by_id) || completed.completed_by_id == admin.id
  end

  test "publishing content does not resurrect an already-done task's completion record" do
    editor = user(:editor)
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Already done", slug: slug()}, actor: editor)

    {:ok, task} =
      CMS.assign_task(
        %{content_type: "page", content_id: page.id, assignee_id: editor.id},
        actor: editor
      )

    {:ok, done} = CMS.complete_task(task, %{}, actor: editor)

    CMS.publish_page!(page, %{}, actor: admin)
    drain()

    unchanged = CMS.get_task!(task.id, authorize?: false)
    assert unchanged.completed_at == done.completed_at
    assert unchanged.completed_by_id == done.completed_by_id
  end

  test "newly_overdue only lists open, past-due tasks not yet notified" do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, overdue} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), -1)
        },
        actor: editor
      )

    {:ok, future} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), 1)
        },
        actor: editor
      )

    ids = CMS.list_newly_overdue_tasks!(authorize?: false) |> Enum.map(& &1.id)
    assert overdue.id in ids
    refute future.id in ids

    {:ok, _} = CMS.mark_task_overdue_notified(overdue, %{}, authorize?: false)
    ids_after = CMS.list_newly_overdue_tasks!(authorize?: false) |> Enum.map(& &1.id)
    refute overdue.id in ids_after

    drain()
  end

  test "reassigning clears the overdue-notified gate" do
    editor = user(:editor)
    assignee = user(:editor)
    other = user(:editor)

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), -1)
        },
        actor: editor
      )

    {:ok, notified} = CMS.mark_task_overdue_notified(task, %{}, authorize?: false)
    refute is_nil(notified.overdue_notified_on)

    {:ok, reassigned} = CMS.update_task(notified, %{assignee_id: other.id}, actor: editor)
    assert is_nil(reassigned.overdue_notified_on)
    drain()
  end
end
