defmodule KilnCMS.CMS.Changes.AutoCompleteTasks do
  @moduledoc """
  On publish, mark the open tasks on this record done (#501) — publishing is
  the natural "done" signal for "get this reviewed/finished", and an editor
  who forgets to close their own task shouldn't leave a stale queue entry
  behind. Reopening is manual (`CMS.reopen_task/2`).

  Attach to `:publish` / `:publish_scheduled`:

      change KilnCMS.CMS.Changes.AutoCompleteTasks

  ## Not every open task (#818)

  It was every one, unconditionally. A task can now opt out
  (`Task.auto_complete_on_publish`), and a site can change the default for the
  ones that haven't (`SiteEditorialSettings`) — the case neither alone serves
  being a follow-up task deliberately outliving the publish it hangs off.

  `KilnCMS.CMS.TaskSettings` owns the precedence.

  ## The site default is resolved BEFORE the transaction, not inside it

  `change/3`'s body runs while the changeset is being built; the `after_action`
  hook runs inside the action's transaction. That distinction is the whole
  reason the read sits where it does.

  A failed `SELECT` inside a Postgres transaction does not merely return an
  error — it aborts the transaction, so every subsequent statement fails with
  `25P02` too. Reading the settings row from the hook would therefore turn a
  missing table (a deploy that ran before its migration) into a **failed
  publish** for any record carrying an open task, and `TaskSettings`'
  degrade-to-`true` branch would never get to run: the error propagates as a
  raise. Publishing had no dependency on this table before #818 and must not
  acquire one.

  Resolved here it is an ordinary read that can fail on its own, so the
  documented fallback applies. The cost is one indexed single-row lookup per
  publish, including publishes of records with no tasks at all — cheaper than
  the alternative is correct.

  A caller that already knows the answer passes it in
  (`context: %{auto_complete_default: bool}`), which is how
  `KilnCMS.CMS.Releases` turns one read per item into one read per release.

  System-scoped (`authorize?: false`): a scheduled publish
  (`:publish_scheduled`) has no acting user, and a manual publish shouldn't
  need its own task-completion permission on top of publish permission.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.CMS.TaskSettings

  @impl true
  def change(changeset, _opts, _context) do
    site_default = resolve_default(changeset)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      content_type = KilnCMS.Firing.Engine.public_type(record)

      content_type
      |> CMS.list_tasks_for!(record.id, authorize?: false, tenant: record.org_id)
      |> Enum.filter(&(&1.status == :open and TaskSettings.auto_complete?(&1, site_default)))
      |> Enum.each(&CMS.complete_task(&1, %{}, authorize?: false, tenant: record.org_id))

      {:ok, record}
    end)
  end

  # `changeset.data.org_id` rather than the resolved record's: the record only
  # exists after the action, and `org_id` is not writable, so the two agree.
  defp resolve_default(changeset) do
    case changeset.context do
      %{auto_complete_default: value} when is_boolean(value) -> value
      _none -> TaskSettings.site_default(changeset.data.org_id)
    end
  end
end
