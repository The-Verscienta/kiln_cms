defmodule KilnCMS.CMS.Changes.NotifyTaskAssigned do
  @moduledoc """
  After a task is assigned (or reassigned), email the assignee and fire the
  `task.assigned` automation/webhook event. Attach to an action:

      change KilnCMS.CMS.Changes.NotifyTaskAssigned
      change {KilnCMS.CMS.Changes.NotifyTaskAssigned, only_when: :reassigned}

  `only_when: :reassigned` (used by `:update`) skips the notification unless
  `assignee_id` actually changed — editing just the due date or note isn't a
  new assignment and shouldn't re-notify.
  """
  use Ash.Resource.Change

  alias KilnCMS.Notifications.Tasks, as: TaskNotifications

  @impl true
  def change(changeset, opts, context) do
    only_when = Keyword.get(opts, :only_when)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if notify?(only_when, changeset) do
        TaskNotifications.dispatch_assigned(record, context.actor)
      end

      {:ok, record}
    end)
  end

  defp notify?(nil, _changeset), do: true

  defp notify?(:reassigned, changeset),
    do: Ash.Changeset.changing_attribute?(changeset, :assignee_id)
end
