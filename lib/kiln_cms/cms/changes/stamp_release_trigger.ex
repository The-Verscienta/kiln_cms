defmodule KilnCMS.CMS.Changes.StampReleaseTrigger do
  @moduledoc """
  Records which admin last claimed a release (#500) — scheduled it, hit "Publish
  now", or started a rollback.

  The go-live worker publishes every item **as this user**, so version history
  and the tamper-evident audit chain attribute a release to a person rather than
  to nobody. That matters precisely because the worker itself necessarily runs
  `authorize?: false`.

  A no-op when there is no actor: the AshOban scheduler claims a *scheduled*
  release with no actor of its own, and the admin who set the schedule is
  already stamped — overwriting them with `nil` would erase the attribution the
  worker depends on.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case context.actor do
      %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :triggered_by_id, id)
      _ -> changeset
    end
  end
end
