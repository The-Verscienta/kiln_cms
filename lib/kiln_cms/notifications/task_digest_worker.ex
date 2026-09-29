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

  ## Runs as the notifier's system actor, and fails closed (#1659)

  The task reads and the "already notified" stamp run as
  `KilnCMS.Notifications.system/0`, which `CMS.Task` admits for reads and for
  `:mark_overdue_notified` alone. A refused read would filter to `[]` — "no
  task is due", "nothing is newly overdue" — and the digest would silently
  stop; both reads use `authorize_with: :error`, so a lost grant fails the job
  where Oban shows it instead.

  The stamp is the dedupe: it and the `task.overdue` dispatch run in one
  transaction, stamp first, so they commit together or not at all. A dispatch
  that raises rolls the stamp back and the retry fires it again; a stamp that
  is refused (or that another run already wrote — the action only stamps an
  unstamped row) fires nothing and leaves the task for tomorrow's run.

  One org's failure does not stop the others: every org is attempted, and the
  job fails afterwards if any did. Digest mails are unique per recipient and
  content for the day, so the retry re-sends none that already went out.
  """
  use Oban.Worker, queue: :mail, max_attempts: 3

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Notifications.Tasks, as: TaskNotifications

  @digest_window_days 3

  @impl Oban.Worker
  def perform(_job) do
    today = Date.utc_today()
    horizon = Date.add(today, @digest_window_days)

    failed = Enum.reject(Accounts.list_org_ids(), &run_for_org(&1, horizon))

    if failed != [] do
      raise "task digest failed for orgs: #{Enum.join(failed, ", ")}"
    end

    :ok
  end

  # True when the org ran clean; a failure is logged and the next org still runs.
  defp run_for_org(org_id, horizon) do
    send_digests(org_id, horizon)
    fire_overdue_events(org_id)
    true
  rescue
    error ->
      Logger.error("task digest failed for org #{org_id}: #{Exception.message(error)}")
      false
  end

  @doc false
  # Public, with the phase below, so a test can take the grant away from each
  # read on its own (#1659) — run in order, the first raise hides the second.
  @spec send_digests(String.t(), Date.t()) :: :ok
  def send_digests(org_id, horizon) do
    horizon
    |> CMS.list_tasks_due_within!(
      actor: Notifications.system(),
      authorize_with: :error,
      tenant: org_id
    )
    # authorize?: false — the assignee is an `Accounts.User`, whose read policy
    # is self-only; a system grant there would cover every account on the
    # deployment to learn the addresses these tasks already name.
    |> Ash.load!(:assignee, authorize?: false)
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
      # Unique for the day: a retry of this job (an org after this one failed)
      # must not mail the same digest twice.
      |> TaskMailWorker.new(unique: [period: 20 * 60 * 60, fields: [:worker, :args]])
      |> Oban.insert!()
    end
  end

  defp enqueue_digest([], _org_id), do: :ok

  @doc false
  @spec fire_overdue_events(String.t()) :: :ok
  def fire_overdue_events(org_id) do
    system = Notifications.system()

    CMS.list_newly_overdue_tasks!(actor: system, authorize_with: :error, tenant: org_id)
    |> Enum.each(&stamp_and_fire(&1, system, org_id))
  end

  # Stamp and fire in one transaction — see the moduledoc. The dispatch only
  # enqueues jobs, and Oban inserts through the same repo, so a raise in it
  # rolls the stamp back with everything it enqueued. The stamp's own Ash
  # notifications are sent once the transaction has committed.
  defp stamp_and_fire(task, system, org_id) do
    KilnCMS.Repo.transaction(fn ->
      case CMS.mark_task_overdue_notified(task, %{},
             actor: system,
             tenant: org_id,
             return_notifications?: true
           ) do
        {:ok, _task, notifications} ->
          TaskNotifications.dispatch_overdue(task)
          notifications

        {:error, error} ->
          KilnCMS.Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        :ok

      {:error, error} ->
        Logger.error(
          "task.overdue not fired for task #{task.id}: could not record it as notified: " <>
            Exception.message(error)
        )
    end
  end
end
