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

  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Webhooks

  @doc """
  A task was assigned (or reassigned): email the assignee and fire the
  `task.assigned` automation/webhook event. Never raises — a notification
  failure must not roll back the assignment that triggered it.
  """
  @spec dispatch_assigned(struct(), map() | nil) :: :ok
  def dispatch_assigned(task, actor) do
    task = Ash.load!(task, [:assignee], authorize?: false)

    if task.assignee && task.assignee.email do
      %{
        "kind" => "assigned",
        "to" => to_string(task.assignee.email),
        "task_id" => task.id,
        "content_type" => task.content_type,
        "content_id" => task.content_id,
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
      "assignee_id" => task.assignee_id,
      "due_on" => task.due_on && Date.to_iso8601(task.due_on)
    }
  end

  defp actor_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_name(_actor), do: nil
end
