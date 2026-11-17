defmodule KilnCMS.Backups.Notice.Changes.Normalize do
  @moduledoc """
  Bounds and scrubs what a `KilnCMS.Backups.Notice` carries (#2487): `reason`
  is redacted and capped at 500 characters, like a run's log line, `label` at
  200, like a run's destination label, and `units` keeps its first ten.

  `reason` and `label` arrive as the action's arguments and are set from
  them here, so the columns' `max_length` can never refuse the write.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.Redact

  @max_reason 500
  @max_label 200
  @max_units 10

  @doc "How many units a notice lists at most."
  @spec max_units() :: pos_integer()
  def max_units, do: @max_units

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> from_argument(:reason, &Redact.text(&1, [], @max_reason))
    |> from_argument(:label, &Redact.text(&1, [], @max_label))
    |> normalize(:units, &Enum.take(&1, @max_units))
  end

  defp from_argument(changeset, field, fun) do
    value =
      case Ash.Changeset.get_argument(changeset, field) do
        nil -> nil
        value -> fun.(value)
      end

    Ash.Changeset.force_change_attribute(changeset, field, value)
  end

  defp normalize(changeset, field, fun) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, nil} -> changeset
      {:ok, value} -> Ash.Changeset.force_change_attribute(changeset, field, fun.(value))
      :error -> changeset
    end
  end
end
