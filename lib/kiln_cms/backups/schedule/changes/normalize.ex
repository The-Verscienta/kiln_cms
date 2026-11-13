defmodule KilnCMS.Backups.Schedule.Changes.Normalize do
  @moduledoc """
  What a `KilnCMS.Backups.Schedule` create or update stores (part of #2219):
  `time_of_day` cut to the minute (a window is a minute), and `components`
  de-duplicated and in `KilnCMS.Backups.Lock.components/0` order, so two
  schedules for the same thing compare equal and an edit that only reorders
  them changes nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.Lock

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> normalize(:time_of_day, &minute/1)
    |> normalize(:components, &components/1)
  end

  defp normalize(changeset, field, fun) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, nil} -> changeset
      {:ok, value} -> Ash.Changeset.force_change_attribute(changeset, field, fun.(value))
      :error -> changeset
    end
  end

  defp minute(%Time{} = time), do: %{time | second: 0, microsecond: {0, 0}}
  defp minute(other), do: other

  defp components(list) when is_list(list), do: Enum.filter(Lock.components(), &(&1 in list))
  defp components(other), do: other
end
