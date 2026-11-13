defmodule KilnCMS.Backups.Schedule.Audit do
  @moduledoc """
  The instance security log entries of a `KilnCMS.Backups.Schedule` create,
  update and destroy (part of #2219): their target and metadata. Each type's
  keys are in `KilnCMS.Security.InstanceEvent`'s allowlist, at most eight.

  Values are scalars: components joined (`"db,media"`), atoms and dates as
  text, `time_of_day` as `HH:MM`. The keep fields are not editable yet (#2219,
  part 3) but are recorded, so the events need no new keys when they are.
  """

  @compared [:components, :interval, :time_of_day, :starts_on, :time_zone, :enabled]
  @keep [:keep_count, :keep_days]

  @doc false
  def target(record, _changeset), do: {"backup_schedule", record.id}

  @doc false
  def created(record, _changeset) do
    %{
      "components" => components(record.components),
      "interval" => text(record.interval),
      "time_of_day" => time(record.time_of_day),
      "time_zone" => record.time_zone,
      "starts_on" => date(record.starts_on),
      "enabled" => record.enabled,
      "keep_count" => record.keep_count,
      "keep_days" => record.keep_days
    }
  end

  @doc false
  def changed(record, changeset) do
    before = changeset.data

    %{
      "changed" => record |> changed_fields(before) |> Enum.join(","),
      "components" => components(record.components),
      "interval" => text(record.interval),
      "enabled" => record.enabled,
      "keep_count_before" => before.keep_count,
      "keep_count_after" => record.keep_count,
      "keep_days_before" => before.keep_days,
      "keep_days_after" => record.keep_days
    }
  end

  @doc false
  def changed?(record, changeset), do: changed_fields(record, changeset.data) != []

  @doc false
  def deleted(record, _changeset) do
    %{
      "components" => components(record.components),
      "interval" => text(record.interval),
      "enabled" => record.enabled,
      "keep_count" => record.keep_count,
      "keep_days" => record.keep_days
    }
  end

  defp changed_fields(record, before) do
    for field <- @compared ++ @keep,
        not KilnCMS.Backups.Schedule.Changes.Rebaseline.same?(
          Map.get(record, field),
          Map.get(before, field)
        ),
        do: Atom.to_string(field)
  end

  defp components(list) when is_list(list), do: Enum.map_join(list, ",", &text/1)
  defp components(_other), do: nil

  defp text(%KilnCMS.Types.UnknownAtom{value: value}), do: value
  defp text(nil), do: nil
  defp text(value), do: to_string(value)

  defp time(%Time{} = time), do: time |> Time.to_string() |> String.slice(0, 5)
  defp time(_other), do: nil

  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(_other), do: nil
end
