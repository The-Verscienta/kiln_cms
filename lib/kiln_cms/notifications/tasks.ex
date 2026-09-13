defmodule KilnCMS.Notifications.Tasks do
  @moduledoc """
  Outbound notifications for editorial tasks (#501) — the task-domain
  counterpart to `KilnCMS.Notifications` (content-workflow events).

  Kept separate rather than folded into `KilnCMS.Notifications.dispatch/3`:
  that module's recipient resolution and mail-worker payload are shaped
  around a *content* record (`record.title`, `__kiln_content_type__`); a
  task's single, already-known recipient (the assignee) and its own
  fields (due date, note) don't fit that shape.
  """
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Webhooks

  @doc """
  A task was assigned (or reassigned): email the assignee, record it in their
  in-app inbox (#1320), and fire the `task.assigned` automation/webhook event.
  Never raises — a notification failure must not roll back the assignment that
  triggered it.

  ## Both channels off the same decision, which here is "always"

  Unlike the content-workflow events, task assignment has **no** per-user
  preference to consult: there is no `User.notify_on_task_assigned`, so the
  mail has always gone to the assignee unconditionally. The in-app row
  follows the same rule, for the same reason the other channels share
  `KilnCMS.Notifications.notify/4` — one decision per event, whatever that
  decision is. If a preference is ever added it is added once, here, and both
  channels move together.

  The in-app row is written even when the assignee has no deliverable address:
  a missing email is a missing *channel*, not an opt-out.
  """
  @spec dispatch_assigned(struct(), map() | nil) :: :ok
  def dispatch_assigned(task, actor) do
    task = Ash.load!(task, [:assignee], authorize?: false)

    if task.assignee do
      Notifications.record_in_app(%{
        user_id: task.assignee_id,
        org_id: task.org_id,
        event: :task_assigned,
        content_type: task.content_type,
        content_id: task.content_id,
        block_id: task.block_id,
        title: content_title(task),
        # The assignment note is what the assignee needs to read, and it is
        # the task's own field rather than a comment body — the same value
        # the email's `note_line/1` renders.
        excerpt: task.note,
        actor_name: actor_name(actor)
      })
    end

    if task.assignee && task.assignee.email do
      %{
        "kind" => "assigned",
        "to" => to_string(task.assignee.email),
        "task_id" => task.id,
        "content_type" => task.content_type,
        "content_id" => task.content_id,
        # Which block, when the task is anchored to one — the assignee opens
        # straight onto the paragraph rather than onto a document and a hunt.
        "block_id" => task.block_id,
        "org_id" => task.org_id,
        "due_on" => task.due_on && Date.to_iso8601(task.due_on),
        "note" => task.note,
        "actor_name" => actor_name(actor)
      }
      |> TaskMailWorker.new()
      |> Oban.insert!()
    end

    Webhooks.dispatch("task.assigned", payload(task), task.org_id)

    :ok
  rescue
    error ->
      Logger.error("Notifications.Tasks.dispatch_assigned failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Fire the `task.overdue` automation/webhook event for a task that just
  crossed into overdue (called once per task — see
  `KilnCMS.CMS.Task`'s `:mark_overdue_notified`).
  """
  @spec dispatch_overdue(struct()) :: :ok
  def dispatch_overdue(task) do
    Webhooks.dispatch("task.overdue", payload(task), task.org_id)
    :ok
  end

  defp payload(task) do
    %{
      "id" => task.id,
      "content_type" => task.content_type,
      "content_id" => task.content_id,
      "block_id" => task.block_id,
      "assignee_id" => task.assignee_id,
      "due_on" => task.due_on && Date.to_iso8601(task.due_on)
    }
  end

  defp actor_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_name(_actor), do: nil

  # The title of the content the task hangs off, for the inbox row — the same
  # resolution (and the same `content_type` fallback when the record is gone)
  # `TaskMailWorker.content_title/3` uses for the email subject. A system read:
  # the assignee's own read policy governs what they may open in the editor,
  # not whether they may be told the name of the thing they were assigned.
  defp content_title(task) do
    case ContentTypes.get_record(task.content_type, task.content_id,
           # System read — see above; the recipient is already decided.
           authorize?: false,
           tenant: task.org_id,
           query: [select: [:id, :title]]
         ) do
      {:ok, %{title: title}} when is_binary(title) -> title
      _unreadable -> task.content_type
    end
  end
end
