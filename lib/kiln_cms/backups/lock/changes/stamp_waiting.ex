defmodule KilnCMS.Backups.Lock.Changes.StampWaiting do
  @moduledoc """
  `:queue_waiting`'s timestamps (#2219): `waiting_requested_at` and
  `waiting_scope_at` set to ONE `DateTime`, so the queued request's scope is
  its own (`KilnCMS.Backups.Chain.waiting_scope/1` compares the two for
  equality). Two `atomic_update(..., expr(now()))` changes are evaluated one
  by one and come out microseconds apart.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    now = DateTime.utc_now()

    changeset
    |> Ash.Changeset.force_change_attribute(:waiting_requested_at, now)
    |> Ash.Changeset.force_change_attribute(:waiting_scope_at, now)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
