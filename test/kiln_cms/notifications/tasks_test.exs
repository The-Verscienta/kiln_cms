defmodule KilnCMS.Notifications.TasksTest do
  @moduledoc """
  Task assignment notifications (#501): an email to the assignee plus a
  `task.assigned` webhook event, and that editing a task's due date/note
  alone (no reassignment) doesn't re-notify.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "tasknotif-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
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

  test "assigning a task emails the assignee and fires task.assigned" do
    editor = user(:editor)
    assignee = user(:editor)

    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["task.assigned"]},
      actor: user(:admin)
    )

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: ~D[2026-09-01],
          note: "Please review"
        },
        actor: editor
      )

    drain()

    assert [email] = sent_emails("Task assigned")
    assert Enum.map(email.to, fn {_name, addr} -> addr end) == [to_string(assignee.email)]
    assert email.html_body =~ "Please review"

    assert [delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
    assert delivery.event == "task.assigned"
    assert delivery.payload["assignee_id"] == assignee.id
    assert delivery.payload["id"] == task.id
  end

  test "reassigning re-notifies the new assignee" do
    editor = user(:editor)
    first = user(:editor)
    second = user(:editor)

    {:ok, task} =
      CMS.assign_task(
        %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: first.id},
        actor: editor
      )

    drain()
    assert [_] = sent_emails("Task assigned")

    CMS.update_task!(task, %{assignee_id: second.id}, actor: editor)
    drain()

    emails = sent_emails("Task assigned")

    assert Enum.any?(emails, fn e -> Enum.map(e.to, &elem(&1, 1)) == [to_string(second.email)] end)
  end

  test "editing only the due date or note does not re-notify" do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, task} =
      CMS.assign_task(
        %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id},
        actor: editor
      )

    drain()
    assert [_] = sent_emails("Task assigned")

    CMS.update_task!(task, %{due_on: ~D[2026-11-01], note: "updated note"}, actor: editor)
    drain()

    assert sent_emails("Task assigned") == []
  end

  test "an author-controlled note is HTML-escaped in the notification body" do
    editor = user(:editor)
    assignee = user(:editor)
    marker = "XSS#{System.unique_integer([:positive])}"
    note = "#{marker} <img src=x onerror=alert(1)>"

    {:ok, _task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          note: note
        },
        actor: editor
      )

    drain()

    assert [email] = sent_emails("Task assigned")
    refute email.html_body =~ "<img src=x onerror=alert(1)>"
    assert email.html_body =~ "&lt;img src=x onerror=alert(1)&gt;"
  end
end
