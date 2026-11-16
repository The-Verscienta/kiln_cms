defmodule KilnCMS.CMS.Changes.EnqueueTitleRegeneration do
  @moduledoc """
  When a dynamic type's `title_template` is set or changed (#2287), enqueue
  `KilnCMS.CMS.Workers.TitleRegenerationWorker` to bring its existing records'
  titles in line.

  After the commit and only for a template that is *there*: clearing the
  template leaves every title as it stands, since there is nothing left to
  derive from. A job is one row, so enqueuing costs the save nothing; the
  worker does the paging.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if is_binary(Ash.Changeset.get_attribute(changeset, :title_template)) and
         Ash.Changeset.changing_attribute?(changeset, :title_template) do
      Ash.Changeset.after_action(changeset, &enqueue/2)
    else
      changeset
    end
  end

  defp enqueue(_changeset, definition) do
    KilnCMS.CMS.Workers.TitleRegenerationWorker.enqueue(definition.name, definition.org_id)
    {:ok, definition}
  end
end
