defmodule KilnCMS.CMS.Changes.AutoCompleteTasks do
  @moduledoc """
  On publish, mark every open task on this record done (#501) — publishing is
  the natural "done" signal for "get this reviewed/finished", and an editor
  who forgets to close their own task shouldn't leave a stale queue entry
  behind. Reopening is manual (`CMS.reopen_task/2`).

  Attach to `:publish` / `:publish_scheduled`:

      change KilnCMS.CMS.Changes.AutoCompleteTasks

  System-scoped (`authorize?: false`): a scheduled publish
  (`:publish_scheduled`) has no acting user, and a manual publish shouldn't
  need its own task-completion permission on top of publish permission.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      content_type = KilnCMS.Firing.Engine.public_type(record)

      content_type
      |> CMS.list_tasks_for!(record.id, authorize?: false, tenant: record.org_id)
      |> Enum.filter(&(&1.status == :open))
      |> Enum.each(&CMS.complete_task(&1, %{}, authorize?: false, tenant: record.org_id))

      {:ok, record}
    end)
  end
end
