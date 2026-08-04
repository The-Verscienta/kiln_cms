defmodule KilnCMS.Events.Occurrences do
  @moduledoc """
  Turns a document's schedule and recurrence fields into dated occurrences
  (#480).

  The join between the two field types and everything that consumes them: ICS,
  the `Event` JSON-LD node, and "what's on next".

  ## Every entry point is windowed

  There is no "all occurrences of this document" function, and that is
  deliberate rather than an omission — a document with `FREQ=DAILY` and no end
  has infinitely many. Callers name a window and a cap;
  `KilnCMS.Events.Recurrence` enforces the cap even if the window is a century.

  ## A non-recurring event is a series of one

  A document with a schedule and no recurrence yields exactly its own start, if
  that start is in the window. Collapsing the two cases here means ICS and
  JSON-LD never branch on "does this repeat".
  """

  alias KilnCMS.CMS.FieldTypes.DatetimeRange
  alias KilnCMS.Events
  alias KilnCMS.Events.Recurrence

  @default_max 200

  @typedoc """
  One dated instance of an event.

  `starts_at`/`ends_at` are UTC instants; `all_day?` says whether the times are
  meaningful (ICS renders an all-day occurrence as `VALUE=DATE`, which is what
  makes a calendar show it as a banner rather than a midnight block).
  """
  @type occurrence :: %{
          starts_at: DateTime.t(),
          ends_at: DateTime.t() | nil,
          all_day?: boolean(),
          time_zone: String.t()
        }

  @doc """
  Occurrences of `record` between `from` and `until`, ascending.

  `[]` when the document carries no schedule field, which is also how a
  non-event type answers — so a caller never has to ask first.

  Options: `:max` (default #{@default_max}), `:org_id`.
  """
  @spec for_record(struct(), DateTime.t(), DateTime.t(), keyword()) :: [occurrence()]
  def for_record(record, from, until, opts \\ []) do
    org_id = Keyword.get(opts, :org_id) || Map.get(record, :org_id)
    max = Keyword.get(opts, :max, @default_max)

    with schedule when not is_nil(schedule) <- Events.schedule_value(record, org_id),
         {start_utc, end_utc} <- DatetimeRange.to_utc(schedule) do
      duration = duration(start_utc, end_utc)
      all_day? = DatetimeRange.all_day?(schedule)
      zone = Map.get(schedule, "time_zone") || Events.default_time_zone()

      record
      |> starts(schedule, org_id, from, until, max)
      |> Enum.map(&occurrence(&1, duration, all_day?, zone))
    else
      _other -> []
    end
  end

  @doc """
  The next occurrence at or after `from`, or `nil`.

  Bounded by a look-ahead horizon rather than searching forever: a rule whose
  next occurrence is beyond it answers `nil`, which for a listing means "not
  coming up" — the honest answer for something 400 days out.
  """
  @spec next(struct(), DateTime.t(), keyword()) :: occurrence() | nil
  def next(record, from, opts \\ []) do
    horizon = Keyword.get(opts, :horizon_days, 400)
    until = DateTime.add(from, horizon * 86_400, :second)

    record
    |> for_record(from, until, Keyword.put(opts, :max, 1))
    |> List.first()
  end

  # The series start instants, from the recurrence rule if there is one.
  defp starts(record, schedule, org_id, from, until, max) do
    {start_utc, _end} = DatetimeRange.to_utc(schedule)

    case Events.recurrence_rule(record, org_id) do
      nil ->
        # A series of one. Still window-filtered, so a past event does not turn
        # up in "what's on".
        if in_window?(start_utc, from, until), do: [start_utc], else: []

      rule ->
        zone = Map.get(schedule, "time_zone") || Events.default_time_zone()

        # The rule repeats from the schedule's *local* start — expansion is
        # wall-clock, so it must be handed local time, not the UTC instant.
        local_start =
          start_utc
          |> DateTime.shift_zone!(zone)
          |> DateTime.to_naive()

        Recurrence.expand(rule, local_start, zone, from, until, max: max)
    end
  end

  defp occurrence(start_utc, duration, all_day?, zone) do
    %{
      starts_at: start_utc,
      ends_at: duration && DateTime.add(start_utc, duration, :second),
      all_day?: all_day?,
      time_zone: zone
    }
  end

  # The *duration* recurs, not the end instant — an event that runs 19:00–21:00
  # runs two hours on every occurrence, including one on the far side of a DST
  # change where the UTC offsets differ.
  defp duration(_start_utc, nil), do: nil
  defp duration(start_utc, end_utc), do: DateTime.diff(end_utc, start_utc, :second)

  defp in_window?(datetime, from, until) do
    DateTime.compare(datetime, from) != :lt and DateTime.compare(datetime, until) != :gt
  end
end
