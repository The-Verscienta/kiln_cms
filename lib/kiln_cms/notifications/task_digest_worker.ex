defmodule KilnCMS.Notifications.TaskDigestWorker do
  @moduledoc """
  Daily cron job (#501): for every org, group open tasks due today-or-earlier
  or within the next `@digest_window_days` days by assignee, and enqueue one
  `TaskMailWorker` digest job per assignee with 1+ such task — "aggregated
  digest rather than per-event spam" (the issue's own wording), unlike
  `KilnCMS.Notifications.Tasks.dispatch_assigned/2`'s one-email-per-assignment.

  Also fires the `task.overdue` automation/webhook event for tasks that just
  crossed into overdue, once each (`KilnCMS.CMS.Task.newly_overdue`/
  `:mark_overdue_notified` — see that resource's moduledoc for why the
  webhook event and the email digest have different repeat semantics).

  Registered via `KilnCMS.Application`'s `@cron_schedules`
  (`KILN_TASK_DIGEST_CRON`), same pattern as the governance-checkpoint and
  link-check cron jobs — disabled entirely unless a schedule is configured.
  """
  use Oban.Worker, queue: :mail, max_attempts: 3

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Notifications.Tasks, as: TaskNotifications

  @digest_window_days 3

  @impl Oban.Worker
  def perform(_job) do
    today = Date.utc_today()
    horizon = Date.add(today, @digest_window_days)

    Enum.each(Accounts.list_org_ids(), &run_for_org(&1, today, horizon))

    :ok
  end

  defp run_for_org(org_id, today, horizon) do
    send_digests(org_id, horizon)
    fire_overdue_events(org_id, today)
  end

  defp send_digests(org_id, horizon) do
    CMS.list_tasks_due_within!(horizon, authorize?: false, tenant: org_id, load: [:assignee])
    |> Enum.group_by(& &1.assignee_id)
    |> Enum.each(fn {_assignee_id, tasks} -> enqueue_digest(tasks, org_id) end)
  end

  defp enqueue_digest([%{assignee: assignee} | _] = tasks, org_id) do
    if assignee && assignee.email do
      %{
        "kind" => "digest",
        "to" => to_string(assignee.email),
        "org_id" => org_id,
        "items" =>
          Enum.map(tasks, fn task ->
            %{
              "content_type" => task.content_type,
              "content_id" => task.content_id,
              "due_on" => task.due_on && Date.to_iso8601(task.due_on)
            }
          end)
      }
      |> TaskMailWorker.new()
      |> Oban.insert!()
    end
  end

  defp enqueue_digest([], _org_id), do: :ok

  defp fire_overdue_events(org_id, _today) do
    CMS.list_newly_overdue_tasks!(authorize?: false, tenant: org_id)
    |> Enum.each(fn task ->
      TaskNotifications.dispatch_overdue(task)
      CMS.mark_task_overdue_notified(task, %{}, authorize?: false, tenant: org_id)
    end)
  end
end
