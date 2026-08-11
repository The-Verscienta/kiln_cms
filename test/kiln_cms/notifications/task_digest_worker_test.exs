defmodule KilnCMS.Notifications.TaskDigestWorkerTest do
  @moduledoc """
  The daily task digest (#501): one email per assignee grouping their
  due-soon/overdue open tasks, and a once-only `task.overdue` webhook event
  per task (`KilnCMS.CMS.Task.newly_overdue`/`:mark_overdue_notified`).
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Notifications.TaskDigestWorker

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "digest-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp sent_emails(subject_match) do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.filter(&String.contains?(&1.subject, subject_match))
  end

  # Drain and discard the assignment emails/webhooks from `assign_task` itself,
  # so a test's own assertions only see what the digest run produced.
  defp settle, do: drain()

  test "one digest email per assignee, listing every due-soon/overdue task" do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, _overdue} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), -1)
        },
        actor: editor
      )

    {:ok, _soon} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), 2)
        },
        actor: editor
      )

    settle()
    assert :ok = perform_job(TaskDigestWorker, %{})
    drain()

    assert [digest] = sent_emails("Your task digest")
    assert Enum.map(digest.to, fn {_name, addr} -> addr end) == [to_string(assignee.email)]
    assert digest.subject == "Your task digest: 2 items"
  end

  test "an assignee with no due-soon/overdue tasks gets no digest" do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, _far} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(Date.utc_today(), 30)
        },
        actor: editor
      )

    settle()
    assert :ok = perform_job(TaskDigestWorker, %{})
    drain()

    assert sent_emails("Your task digest") == []
  end

  test "fires task.overdue once per task, not once per digest run" do
    editor = user(:editor)
    assignee = user(:editor)

    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["task.overdue"]},
      actor: user(:admin)
    )

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

    settle()

    assert :ok = perform_job(TaskDigestWorker, %{})
    drain()
    assert :ok = perform_job(TaskDigestWorker, %{})
    drain()

    deliveries =
      CMS.recent_webhook_deliveries!(authorize?: false)
      |> Enum.filter(&(&1.event == "task.overdue"))

    assert [delivery] = deliveries
    assert delivery.payload["id"] == task.id

    reloaded = CMS.get_task!(task.id, authorize?: false)
    refute is_nil(reloaded.overdue_notified_on)
  end
end
