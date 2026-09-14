defmodule KilnCMS.CMS.Changes.NotifyTaskAssigned do
  @moduledoc """
  After a task is assigned (or reassigned), notify the assignee — email plus
  the in-app inbox (#1320) — and fire the `task.assigned` automation/webhook
  event. Attach to an action:

      change KilnCMS.CMS.Changes.NotifyTaskAssigned
      change {KilnCMS.CMS.Changes.NotifyTaskAssigned, only_when: :reassigned}

  `only_when: :reassigned` (used by `:update`) skips the notification unless
  `assignee_id` actually changed — editing just the due date or note isn't a
  new assignment and shouldn't re-notify.

  ## `after_transaction`, not `after_action`

  `KilnCMS.Notifications.Tasks.dispatch_assigned/2` loads the assignee, reads
  the task's content for a title, and inserts a notification row — queries,
  all of which would run inside the assignment's own transaction under
  `after_action`. A failed query there poisons the Postgres transaction and
  the assignment comes back as an opaque `:rollback`, losing the task itself;
  no rescue in the notifier can recover that. Post-commit, the worst case is a
  notification nobody receives about a task that did save.

  Same reason `KilnCMS.CMS.Changes.NotifyComment` and
  `KilnCMS.CMS.Changes.NotifyWorkflowEmail` use the later hook. The
  `{:error, _}` clause falls through untouched, so a rolled-back assignment
  notifies nobody.
  """
  use Ash.Resource.Change

  alias KilnCMS.Notifications.Tasks, as: TaskNotifications

  @impl true
  def change(changeset, opts, context) do
    only_when = Keyword.get(opts, :only_when)

    # The hook's own changeset argument answers "did the assignee change?",
    # exactly as it did under `after_action` — the hook moved, the decision
    # did not.
    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      dispatch(result, notify?(only_when, changeset), context.actor)
    end)
  end

  defp dispatch({:ok, task} = result, true, actor) do
    TaskNotifications.dispatch_assigned(task, actor)
    result
  end

  defp dispatch(result, _notify?, _actor), do: result

  defp notify?(nil, _changeset), do: true

  defp notify?(:reassigned, changeset),
    do: Ash.Changeset.changing_attribute?(changeset, :assignee_id)
end
