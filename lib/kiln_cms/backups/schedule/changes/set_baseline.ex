defmodule KilnCMS.Backups.Schedule.Changes.SetBaseline do
  @moduledoc """
  A new schedule's `baseline_at`: now, by the **node** clock, never SQL
  `now()`. The scheduler computes windows against its node's clock, so the
  baseline must come from the same kind of clock; no window before it fires.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.force_change_attribute(changeset, :baseline_at, DateTime.utc_now())
end
