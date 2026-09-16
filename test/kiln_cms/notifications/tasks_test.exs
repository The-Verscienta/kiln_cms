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

  # The inbox row's title is resolved through the content-type registry, which
  # *raises* for a type it does not know. That lookup runs first, so before it
  # was rescued on its own the whole dispatch bailed out — no email, no
  # webhook — because an inbox row could not find a title.
  test "a content type the registry does not know still emails and fires task.assigned" do
    editor = user(:editor)
    assignee = user(:editor)

    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["task.assigned"]},
      actor: user(:admin)
    )

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "vanishedtype",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id
        },
        actor: editor
      )

    assert [row] = KilnCMS.Notifications.notifications_for_user!(assignee.id, actor: assignee)
    # No record to name, so the type stands in — the email's own fallback.
    assert row.title == "vanishedtype"
    assert row.actor_id == editor.id

    # The *enqueue* is what the rescue restores; pinned before draining, since
    # what the mail job then does with an unknown type is its own concern.
    assert_enqueued worker: KilnCMS.Notifications.TaskMailWorker, args: %{"task_id" => task.id}

    drain()

    assert [delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
    assert delivery.event == "task.assigned"
    assert delivery.payload["id"] == task.id

    # The mail job resolves the title itself, and the unknown type raised
    # there too — the job retried to discard and no mail was ever sent.
    assert [email] = sent_emails("Task assigned")
    assert email.subject == "Task assigned: vanishedtype"

    # A block-scoped task also looks the record up for its block line.
    {:ok, _block_task} =
      CMS.assign_task(
        %{
          content_type: "vanishedtype",
          content_id: Ecto.UUID.generate(),
          block_id: Ecto.UUID.generate(),
          assignee_id: assignee.id
        },
        actor: editor
      )

    drain()

    assert [block_email] = sent_emails("Task assigned")
    assert block_email.subject == "Task assigned: vanishedtype"
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
