defmodule KilnCMS.Backups.Schedule.Changes.SetLastError do
  @moduledoc """
  `last_error` from the action's `reason` argument, redacted
  (`KilnCMS.Backups.Redact`) and cut to 500 characters, so the column's
  `max_length` can never refuse the write that records why a window did not
  run.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.Redact

  @max 500

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.force_change_attribute(changeset, :last_error, value(changeset))

  @impl true
  def atomic(changeset, _opts, _context), do: {:atomic, %{last_error: value(changeset)}}

  defp value(changeset) do
    changeset |> Ash.Changeset.get_argument(:reason) |> to_string() |> Redact.text([], @max)
  end
end
