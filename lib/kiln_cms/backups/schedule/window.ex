defmodule KilnCMS.Backups.Schedule.Window do
  @moduledoc """
  A backup schedule's windows (part of #2219): when it fires, computed from
  its interval, local time of day, start date and time zone. Pure: no clock,
  no database. The caller passes `now` (the node clock).

  A **window** is one occurrence, identified by its UTC instant (microsecond
  precision, as `last_window_at` stores it).

  ## How occurrences are built

  Per local date in the schedule's zone, never by adding seconds to an
  instant (a day is not always 86 400 s): each date's slot times become
  `NaiveDateTime`s and go through `KilnCMS.Events.to_utc/2`, the codebase's
  one rule for DST.

    * **A DST gap** moves the occurrence forward past the gap (02:30 on a
      spring-forward night fires at 03:00 local); it still fires once.
    * **An ambiguous time** (fall back) is its first instant. The window is
      the UTC instant, so the second wall-clock 01:30 is never an occurrence.
    * **Sub-daily intervals** (every 2, 4, 8 or 12 hours) have slots at
      `time_of_day + k × N` hours, modulo a day. On a transition day two slots
      can be 1 h or 3 h apart instead of 2 h.
    * **Weekly** fires on `starts_on`'s weekday, **fortnightly** on that
      weekday in weeks an even number of weeks from `starts_on`, **monthly**
      on `starts_on`'s day of the month, clamped to the month's last day.
    * Nothing fires on a local date before `starts_on`.

  ## Catch-up

  Only the latest due window fires (`due/2`); windows skipped while nothing
  ticked are not backfilled, and are reported as missed (`missed?/2`).

  ## Invalid schedules

  An interval this release doesn't know (`KilnCMS.Types.UnknownAtom`, written
  by a newer release), an unknown time zone or unknown components make every
  function return `{:error, :invalid}` (`missed?/2`: `false`). Nothing here
  raises on a stored row.
  """

  alias KilnCMS.Backups.Lock
  alias KilnCMS.Backups.Schedule
  alias KilnCMS.Events

  @type schedule :: %{
          required(:interval) => term(),
          required(:time_of_day) => term(),
          required(:starts_on) => term(),
          required(:time_zone) => term(),
          optional(:baseline_at) => DateTime.t() | nil,
          optional(:last_window_at) => DateTime.t() | nil,
          optional(:components) => term(),
          optional(atom()) => term()
        }

  @type result :: {:ok, DateTime.t() | nil} | {:error, :invalid}

  @hours %{
    every_2h: 2,
    every_4h: 4,
    every_8h: 8,
    every_12h: 12,
    daily: 24,
    weekly: 168,
    fortnightly: 336,
    monthly: 744
  }

  # Local dates enumerated around `now` when looking for the latest or next
  # occurrence: one period, plus a day of slack either side.
  @span_days %{weekly: 8, fortnightly: 15, monthly: 32}

  @doc """
  How long after the last good backup a component covered by a schedule of
  `interval` is called stale: the interval plus half of it, at least six
  hours of slack. Daily gives 36, the same as `BACKUP_STALE_AFTER_HOURS`'s
  default.
  """
  @spec stale_after_hours(atom()) :: pos_integer() | nil
  def stale_after_hours(interval) do
    case Map.fetch(@hours, interval) do
      {:ok, h} -> h + max(div(h, 2), 6)
      :error -> nil
    end
  end

  @doc "Every occurrence on a local date from `from` to `to` (inclusive), in order."
  @spec occurrences(schedule(), Date.t(), Date.t()) :: {:ok, [DateTime.t()]} | {:error, :invalid}
  def occurrences(s, %Date{} = from, %Date{} = to) do
    with :ok <- validate(s), do: {:ok, build(s, from, to)}
  end

  @doc "The newest occurrence at or before `now`, or nil (none yet: `starts_on` ahead)."
  @spec latest(schedule(), DateTime.t()) :: result()
  def latest(s, %DateTime{} = now) do
    with :ok <- validate(s), do: {:ok, latest_valid(s, now)}
  end

  @doc "The newest occurrence strictly before `w`, or nil."
  @spec previous(schedule(), DateTime.t()) :: result()
  def previous(s, %DateTime{} = w), do: latest(s, DateTime.add(w, -1, :microsecond))

  @doc """
  The earliest occurrence after `now` that is not before `baseline_at` (an
  occurrence before the baseline never fires).
  """
  @spec next(schedule(), DateTime.t()) :: result()
  def next(s, %DateTime{} = now) do
    with :ok <- validate(s) do
      floor = later(now, Map.get(s, :baseline_at))
      {:ok, next_valid(s, now, floor, local_date(floor, s.time_zone), 4)}
    end
  end

  @doc """
  The window to fire now, or nil: the latest occurrence, when it is not
  before `baseline_at` and is after `last_window_at`.
  """
  @spec due(schedule(), DateTime.t()) :: result()
  def due(s, %DateTime{} = now) do
    with {:ok, w} <- latest(s, now) do
      {:ok, if(w != nil and fires?(s, w), do: w)}
    end
  end

  @doc """
  Whether firing `w` skips earlier windows: the schedule claimed a window
  before, and the occurrence before `w` is newer than that one and not
  before the baseline (a window before the baseline was never owed, so
  resuming a paused schedule misses nothing).
  """
  @spec missed?(schedule(), DateTime.t()) :: boolean()
  def missed?(s, %DateTime{} = w) do
    case {Map.get(s, :last_window_at), previous(s, w)} do
      {%DateTime{} = last, {:ok, %DateTime{} = prev}} ->
        DateTime.compare(last, prev) == :lt and not before?(prev, Map.get(s, :baseline_at))

      _ ->
        false
    end
  end

  ## Internals

  defp fires?(s, w) do
    not before?(w, Map.get(s, :baseline_at)) and
      case Map.get(s, :last_window_at) do
        %DateTime{} = last -> DateTime.compare(w, last) == :gt
        _none -> true
      end
  end

  defp before?(_at, nil), do: false
  defp before?(at, %DateTime{} = ref), do: DateTime.compare(at, ref) == :lt

  defp later(now, %DateTime{} = baseline),
    do: if(DateTime.compare(baseline, now) == :gt, do: baseline, else: now)

  defp later(now, _none), do: now

  defp latest_valid(s, now) do
    today = local_date(now, s.time_zone)

    s
    |> build(Date.add(today, -span(s.interval)), Date.add(today, 1))
    |> Enum.filter(&(DateTime.compare(&1, now) != :gt))
    |> List.last()
  end

  # Strictly after `now`, at or after `floor`. Searches forward a span at a
  # time from `from` (the first date not yet looked at, never before
  # `starts_on`), a few spans at most.
  defp next_valid(_s, _now, _floor, _from, 0), do: nil

  defp next_valid(s, now, floor, from, tries) do
    from = Date.add(max_date(from, s.starts_on), -1)
    to = Date.add(from, span(s.interval) + 1)

    found =
      Enum.find(
        build(s, from, to),
        &(DateTime.compare(&1, now) == :gt and DateTime.compare(&1, floor) != :lt)
      )

    found || next_valid(s, now, floor, Date.add(to, 1), tries - 1)
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp span(interval), do: Map.get(@span_days, interval, 2)

  defp build(s, from, to) do
    from = max_date(from, s.starts_on)

    if Date.compare(from, to) == :gt do
      []
    else
      Date.range(from, to)
      |> Enum.filter(&on_date?(s, &1))
      |> Enum.flat_map(fn date -> Enum.flat_map(slots(s), &instant(date, &1, s.time_zone)) end)
      |> Enum.uniq_by(&DateTime.to_unix(&1, :microsecond))
      |> Enum.sort(DateTime)
    end
  end

  defp instant(date, time, zone) do
    with {:ok, naive} <- NaiveDateTime.new(date, time),
         {:ok, utc} <- Events.to_utc(naive, zone) do
      # A gap's instant comes back at second precision; a window is stored
      # (and compared by tests) at microsecond precision.
      [%{utc | microsecond: {0, 6}}]
    else
      _ -> []
    end
  end

  defp on_date?(%{interval: :weekly, starts_on: start}, date),
    do: Date.day_of_week(date) == Date.day_of_week(start)

  defp on_date?(%{interval: :fortnightly, starts_on: start}, date),
    do: Date.day_of_week(date) == Date.day_of_week(start) and rem(Date.diff(date, start), 14) == 0

  defp on_date?(%{interval: :monthly, starts_on: start}, date),
    do: date.day == min(start.day, Date.days_in_month(date))

  defp on_date?(_s, _date), do: true

  defp slots(%{interval: interval, time_of_day: time}) do
    hours = Map.fetch!(@hours, interval)
    base = %{time | second: 0, microsecond: {0, 6}}

    times =
      if hours < 24,
        do: for(k <- 0..(div(24, hours) - 1), do: %{base | hour: rem(base.hour + k * hours, 24)}),
        else: [base]

    Enum.sort(times, Time)
  end

  defp local_date(%DateTime{} = at, zone) do
    at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
  end

  defp validate(s) do
    if valid?(s), do: :ok, else: {:error, :invalid}
  end

  defp valid?(
         %{interval: interval, time_of_day: %Time{}, starts_on: %Date{}, time_zone: zone} = s
       ) do
    is_atom(interval) and interval in Schedule.intervals() and Events.known_time_zone?(zone) and
      valid_components?(Map.get(s, :components, [:db]))
  end

  defp valid?(_s), do: false

  defp valid_components?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &(&1 in Lock.components()))

  defp valid_components?(_other), do: false
end
