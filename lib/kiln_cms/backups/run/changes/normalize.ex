defmodule KilnCMS.Backups.Run.Changes.Normalize do
  @moduledoc """
  Bounds and scrubs what a `KilnCMS.Backups.Run` write carries (#2217): the log
  goes through `KilnCMS.Backups.Log.cap/1` (at most 200 entries of 500 characters,
  redacted), the error through `KilnCMS.Backups.Redact` and a 4 000-character
  cap, and the trigger — an operator-supplied string — is capped at 64. Each
  off-site destination's `error` and `label` (#2220) are redacted and capped
  at 500 and 200.

  Runs on every write action, so no caller has to remember it.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.{Log, Redact}

  @max_error 4_000
  @max_trigger 64
  @max_destination_error 500
  @max_destination_label 200

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> normalize(:log, &Log.cap/1)
    |> normalize(:error, &Redact.text(&1, [], @max_error))
    |> normalize(:trigger, &trigger/1)
    |> normalize(:destinations, &destinations/1)
  end

  @doc """
  An operator-supplied trigger as a Run stores it: redacted and cut to 64
  characters. `KilnCMS.Backups.Chain` applies it before the lock row sees one.
  """
  @spec trigger(String.t()) :: String.t()
  def trigger(value), do: Redact.text(value, [], @max_trigger)

  defp destinations(entries) when is_list(entries), do: Enum.map(entries, &destination/1)

  defp destination(%{} = entry) do
    entry
    |> scrub(:error, @max_destination_error)
    |> scrub(:label, @max_destination_label)
  end

  defp scrub(entry, field, max) do
    case Map.get(entry, field) do
      text when is_binary(text) -> Map.put(entry, field, Redact.text(text, [], max))
      _none -> entry
    end
  end

  defp normalize(changeset, field, fun) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, nil} -> changeset
      {:ok, value} -> Ash.Changeset.force_change_attribute(changeset, field, fun.(value))
      :error -> changeset
    end
  end
end
