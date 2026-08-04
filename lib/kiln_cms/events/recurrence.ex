defmodule KilnCMS.Events.Recurrence do
  @moduledoc """
  An RFC 5545 recurrence subset, and a **bounded** expansion of it (#480).

  A recurring event is a rule, not a list. "Every second Tuesday until March"
  is one row; the occurrences are derived on demand, inside a window a caller
  names. Nothing here ever materializes an unbounded series.

  ## Why bounded is a correctness property, not a precaution

  `FREQ=SECONDLY` with no `UNTIL` and no `COUNT` is a legal rule. So is
  `FREQ=DAILY;UNTIL=99991231T000000Z`. Expanding either without a ceiling is a
  denial of service an editor can type into a form. Every entry point therefore
  takes a window *and* a hard `:max` (default `@default_max`), and expansion
  stops at whichever comes first — so a caller cannot ask for "all of them" even
  by mistake.

  ## Wall-clock, not UTC

  This is the reason the project now has a timezone database at all. "Every
  Tuesday at 19:00" means 19:00 *local*, on both sides of a DST boundary — the
  UTC instant moves by an hour and the rule does not. So expansion walks in the
  event's own zone and converts each occurrence to UTC at the end, rather than
  adding 7×86400 seconds to an instant.

  Two edge cases that arithmetic produces and this handles explicitly:

    * **A skipped local time.** On a spring-forward day 01:30 does not exist. An
      occurrence landing there is shifted forward past the gap rather than
      dropped — an editor who scheduled a weekly 01:30 slot expects 52 of them.
    * **An ambiguous local time.** On an autumn-back day 01:30 happens twice.
      The *first* is used, deterministically, because "the meeting is at 01:30"
      means the first one and picking the later one silently moves it an hour.

  ## The subset

  `FREQ` (`DAILY` `WEEKLY` `MONTHLY` `YEARLY`), `INTERVAL`, `COUNT`, `UNTIL`,
  `BYDAY` (weekly, plus an optional ordinal for monthly — `2TU`), `BYMONTHDAY`,
  and `EXDATE`. Deliberately not the whole spec: `BYSETPOS`, `BYWEEKNO`,
  `BYYEARDAY` and sub-daily frequencies are rejected at parse time rather than
  silently ignored, because an editor whose rule is quietly reinterpreted gets a
  calendar that is wrong in a way nothing surfaces.

  A rejected rule is an error at *parse* time, which is the field type's
  validation — so it never reaches storage and never has to be reinterpreted at
  render time.
  """

  @default_max 200
  @hard_max 1_000

  @frequencies ~w(DAILY WEEKLY MONTHLY YEARLY)
  @weekdays %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}

  @type t :: %__MODULE__{
          freq: :daily | :weekly | :monthly | :yearly,
          interval: pos_integer(),
          count: pos_integer() | nil,
          until: Date.t() | nil,
          by_day: [{integer() | nil, 1..7}],
          by_month_day: [integer()],
          by_month: [1..12],
          ex_dates: [Date.t()]
        }

  defstruct freq: :daily,
            interval: 1,
            count: nil,
            until: nil,
            by_day: [],
            by_month_day: [],
            by_month: [],
            ex_dates: []

  @doc "The default ceiling on how many occurrences a single expansion returns."
  @spec default_max() :: pos_integer()
  def default_max, do: @default_max

  @doc """
  Parse an RRULE string (optionally with a trailing `EXDATE=` part).

      "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;UNTIL=20260301"

  `{:ok, rule}` or `{:error, message}`. The message is shown to an editor, so it
  names what was wrong rather than saying "invalid".
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(rrule) when is_binary(rrule) do
    rrule
    |> String.trim()
    |> String.upcase()
    |> String.replace_prefix("RRULE:", "")
    |> String.split(";", trim: true)
    |> Enum.reduce_while({:ok, %__MODULE__{}, false}, &apply_part/2)
    |> case do
      {:ok, _rule, false} -> {:error, "needs a FREQ (DAILY, WEEKLY, MONTHLY or YEARLY)"}
      {:ok, rule, true} -> validate(rule)
      {:error, message} -> {:error, message}
    end
  end

  def parse(_rrule), do: {:error, "must be a string"}

  @doc """
  Render a rule back to an RRULE string — what ICS and storage carry.

  `:until` picks `UNTIL`'s value type: `:date` (the default, and what storage
  round-trips through `parse/1`) or `:datetime`. RFC 5545 §3.3.10 requires
  `UNTIL` to match `DTSTART`'s value type, so a timed event's rule must render
  the datetime form — a date-only `UNTIL` against a DATE-TIME `DTSTART` is
  malformed, and a client that coerces it to midnight drops the last day of the
  series that Kiln's own expansion (which compares dates inclusively) keeps.
  """
  @spec to_rrule(t(), keyword()) :: String.t()
  def to_rrule(%__MODULE__{} = rule, opts \\ []) do
    [
      "FREQ=#{rule.freq |> to_string() |> String.upcase()}",
      rule.interval > 1 && "INTERVAL=#{rule.interval}",
      rule.count && "COUNT=#{rule.count}",
      rule.until && "UNTIL=#{render_until(rule.until, Keyword.get(opts, :until, :date))}",
      rule.by_month != [] && "BYMONTH=" <> Enum.join(rule.by_month, ","),
      rule.by_day != [] && "BYDAY=" <> Enum.map_join(rule.by_day, ",", &render_day/1),
      rule.by_month_day != [] && "BYMONTHDAY=" <> Enum.join(rule.by_month_day, ",")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(";")
  end

  defp render_until(date, :date), do: Calendar.strftime(date, "%Y%m%d")

  # End-of-day UTC, because the stored `until` is an inclusive *date* and that
  # is how expansion treats it: `20260303T000000Z` would silently drop 3 March.
  defp render_until(date, :datetime), do: Calendar.strftime(date, "%Y%m%dT235959Z")

  @doc """
  Occurrences of `rule` starting at `dtstart`, within `[from, until]`, in
  `time_zone`.

  `dtstart` is a `NaiveDateTime` — the event's *local* wall time, which is what
  a recurrence rule is written against. Returns UTC `DateTime`s, ascending.

  Options: `:max` (capped at #{@hard_max}), `:ex_dates`.

  The window and the cap are both real: expansion walks candidate dates from
  `dtstart` and stops at `until`, at `COUNT`, at the rule's own `UNTIL`, or at
  `:max`, whichever is reached first. A rule that would produce millions inside
  the window returns `:max` of them, not millions.
  """
  @spec expand(t(), NaiveDateTime.t(), String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          [DateTime.t()]
  def expand(%__MODULE__{} = rule, dtstart, time_zone, from, until, opts \\ []) do
    max = opts |> Keyword.get(:max, @default_max) |> min(@hard_max) |> max(0)
    ex_dates = MapSet.new(rule.ex_dates ++ Keyword.get(opts, :ex_dates, []))

    # The rule's own UNTIL and the caller's window are both ceilings; walking to
    # the earlier of them is what makes "until: 9999" cost nothing.
    # `+1` day on the window end, because candidate *dates* are local while
    # `until` is a UTC instant: in a zone ahead of UTC the local date can be a
    # day past the UTC date while the instant is still inside the window, and
    # the walk would stop one occurrence early. `in_window?/3` below does the
    # real filtering on instants, so the extra day costs one wasted candidate,
    # never an extra result. The rule's own UNTIL is a local date already and
    # needs no such padding.
    window_end = until |> DateTime.to_date() |> Date.add(1)
    stop_date = earliest_date(rule.until, window_end)

    start_date = NaiveDateTime.to_date(dtstart)

    rule
    |> default_by_day(start_date)
    |> candidate_dates(start_date, stop_date)
    # COUNT is counted from the series start, not from the window — an occurrence
    # before `from` still consumes one, or a window into the middle of a
    # `COUNT=10` series would report ten more.
    #
    # And it is counted BEFORE the exclusions: RFC 5545 §3.8.5.1 generates the
    # set from the RRULE, COUNT included, and subtracts EXDATE from *that*.
    # Rejecting first silently backfills each cancelled date with an extra one
    # at the tail, so `COUNT=10` with one EXDATE gave Kiln ten occurrences and
    # every subscribed client nine — a date the site advertises and the
    # calendar does not have.
    |> take_count(rule.count)
    |> Stream.reject(&MapSet.member?(ex_dates, &1))
    |> Stream.map(&at_local_time(&1, NaiveDateTime.to_time(dtstart), time_zone))
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(&in_window?(&1, from, until))
    |> Enum.take(max)
  end

  @doc """
  The next occurrence at or after `from`, or `nil`.

  A one-call wrapper over `expand/6` with a bounded look-ahead, for "when is
  this on next?" — the question a listing sorts by.
  """
  @spec next_occurrence(t(), NaiveDateTime.t(), String.t(), DateTime.t(), keyword()) ::
          DateTime.t() | nil
  def next_occurrence(rule, dtstart, time_zone, from, opts \\ []) do
    horizon = Keyword.get(opts, :horizon_days, 400)
    until = DateTime.add(from, horizon * 86_400, :second)

    rule
    |> expand(dtstart, time_zone, from, until, max: 1)
    |> List.first()
  end

  # RFC 5545 defaults an unspecified BY* part from DTSTART: a WEEKLY rule with no
  # BYDAY recurs on DTSTART's weekday, and a MONTHLY/YEARLY rule with neither
  # BYDAY nor BYMONTHDAY recurs on DTSTART's day of the month.
  #
  # Applied here rather than at parse time because the rule alone does not know
  # its start — and a rule stored without those parts should keep meaning "the
  # same weekday/day as this event" if the event is later moved.
  defp default_by_day(%{freq: :weekly, by_day: []} = rule, start_date),
    do: %{rule | by_day: [{nil, Date.day_of_week(start_date)}]}

  defp default_by_day(%{freq: freq, by_day: [], by_month_day: []} = rule, start_date)
       when freq in [:monthly, :yearly],
       do: %{rule | by_month_day: [start_date.day]}

  defp default_by_day(rule, _start_date), do: rule

  # ── parsing ───────────────────────────────────────────────────────────────

  defp apply_part(part, {:ok, rule, seen_freq?}) do
    case String.split(part, "=", parts: 2) do
      [key, value] -> put_part(rule, seen_freq?, key, value)
      _other -> {:halt, {:error, "couldn't read #{inspect(part)}"}}
    end
  end

  defp put_part(rule, _seen, "FREQ", value) when value in @frequencies,
    do:
      {:cont,
       {:ok, %{rule | freq: value |> String.downcase() |> String.to_existing_atom()}, true}}

  defp put_part(_rule, _seen, "FREQ", value),
    do: {:halt, {:error, "FREQ #{value} isn't supported — use DAILY, WEEKLY, MONTHLY or YEARLY"}}

  defp put_part(rule, seen, "INTERVAL", value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:cont, {:ok, %{rule | interval: n}, seen}}
      _other -> {:halt, {:error, "INTERVAL must be a positive whole number"}}
    end
  end

  defp put_part(rule, seen, "COUNT", value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:cont, {:ok, %{rule | count: n}, seen}}
      _other -> {:halt, {:error, "COUNT must be a positive whole number"}}
    end
  end

  defp put_part(rule, seen, "UNTIL", value) do
    case parse_date(value) do
      {:ok, date} -> {:cont, {:ok, %{rule | until: date}, seen}}
      :error -> {:halt, {:error, "UNTIL must be a date like 20260301"}}
    end
  end

  defp put_part(rule, seen, "BYDAY", value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn day, {:ok, acc} ->
      case parse_day(day) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, {:error, "BYDAY #{day} isn't a weekday like TU or 2TU"}}
      end
    end)
    |> case do
      {:ok, days} -> {:cont, {:ok, %{rule | by_day: Enum.reverse(days)}, seen}}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  defp put_part(rule, seen, "BYMONTHDAY", value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn day, {:ok, acc} ->
      case Integer.parse(day) do
        {n, ""} when n in -31..31 and n != 0 -> {:cont, {:ok, [n | acc]}}
        _other -> {:halt, {:error, "BYMONTHDAY #{day} must be 1..31 or -1..-31"}}
      end
    end)
    |> case do
      {:ok, days} -> {:cont, {:ok, %{rule | by_month_day: Enum.reverse(days)}, seen}}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  defp put_part(rule, seen, "BYMONTH", value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn month, {:ok, acc} ->
      case Integer.parse(month) do
        {n, ""} when n in 1..12 -> {:cont, {:ok, [n | acc]}}
        _other -> {:halt, {:error, "BYMONTH #{month} must be 1..12"}}
      end
    end)
    |> case do
      {:ok, months} -> {:cont, {:ok, %{rule | by_month: Enum.reverse(months)}, seen}}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  defp put_part(rule, seen, "EXDATE", value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn date, {:ok, acc} ->
      case parse_date(date) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, {:error, "EXDATE #{date} must be a date like 20260301"}}
      end
    end)
    |> case do
      {:ok, dates} -> {:cont, {:ok, %{rule | ex_dates: Enum.reverse(dates)}, seen}}
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  # Rejected, not ignored. A rule quietly reinterpreted gives an editor a
  # calendar that is wrong in a way nothing surfaces — far worse than a form
  # error at the moment they typed it.
  defp put_part(_rule, _seen, key, _value)
       when key in ~w(BYSETPOS BYWEEKNO BYYEARDAY BYHOUR BYMINUTE BYSECOND),
       do: {:halt, {:error, "#{key} isn't supported"}}

  # Expansion walks Monday-start weeks (`Date.day_of_week/1`'s default), so MO is
  # the only week start this module actually honours. Any other value changes
  # which fortnight an `INTERVAL=2;BYDAY=SU` occurrence lands in, so it is
  # refused rather than accepted and ignored — the one part that was silently
  # reinterpreted in a module whose whole thesis is that none are.
  defp put_part(rule, seen, "WKST", "MO"), do: {:cont, {:ok, rule, seen}}

  defp put_part(_rule, _seen, "WKST", value),
    do: {:halt, {:error, "WKST=#{value} isn't supported — weeks start on Monday"}}

  defp put_part(_rule, _seen, key, _value),
    do: {:halt, {:error, "#{key} isn't a known rule part"}}

  defp validate(%{count: count, until: until}) when not is_nil(count) and not is_nil(until),
    do: {:error, "use COUNT or UNTIL, not both"}

  # `Enum.any?` over the whole list, not a match on its head: `BYDAY=MO,2TU`
  # slipped through a head-only check, then expanded as "every Tuesday" while
  # `to_rrule/1` re-emitted the ordinal a client would reject.
  defp validate(%{freq: freq, by_day: by_day} = rule)
       when freq not in [:monthly, :yearly] do
    if Enum.any?(by_day, fn {ordinal, _weekday} -> not is_nil(ordinal) end) do
      {:error, "an ordinal BYDAY like 2TU only works with MONTHLY or YEARLY"}
    else
      validate_ignored(rule)
    end
  end

  defp validate(rule), do: validate_ignored(rule)

  # A part the chosen frequency does not read is a part that would be *silently
  # reinterpreted*: `FREQ=DAILY;BYDAY=MO,WE,FR` expanded to every day here while
  # `to_rrule/1` handed the subscriber's client Mon/Wed/Fri. Two different
  # calendars from one saved rule, with nothing to tell an editor.
  defp validate_ignored(%{freq: :daily, by_day: [_ | _]}),
    do: {:error, "BYDAY isn't supported with FREQ=DAILY — use FREQ=WEEKLY"}

  defp validate_ignored(%{freq: :daily, by_month_day: [_ | _]}),
    do: {:error, "BYMONTHDAY isn't supported with FREQ=DAILY — use FREQ=MONTHLY"}

  defp validate_ignored(%{freq: :weekly, by_month_day: [_ | _]}),
    do: {:error, "BYMONTHDAY isn't supported with FREQ=WEEKLY — use FREQ=MONTHLY"}

  defp validate_ignored(rule), do: {:ok, rule}

  # The ordinal is bounded to ±1..5. `0TU` has no meaning, and both it and an
  # out-of-range `-6TU` used to reach `Enum.at/2`, whose *negative* indexing
  # counts from the end — so `-6TU` in a four-Tuesday month silently became the
  # third Tuesday, and `0TU` made the event vanish from every surface.
  defp parse_day(day) do
    case Regex.run(~r/\A(-?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)\z/, day) do
      [_, "", code] -> {:ok, {nil, @weekdays[code]}}
      [_, ordinal, code] -> ordinal_day(String.to_integer(ordinal), @weekdays[code])
      [_, code] -> {:ok, {nil, @weekdays[code]}}
      _other -> :error
    end
  end

  # `20260301` and `20260301T120000Z` both appear in the wild; only the date
  # part matters here, since UNTIL is compared against candidate dates.
  defp parse_date(value) do
    case Regex.run(~r/\A(\d{4})(\d{2})(\d{2})/, value) do
      # `Date.new/3` answers `{:error, :invalid_date}`, not `:error`, so a real
      # calendar impossibility (`20260230`) has to be collapsed here. Leaving it
      # raw made every caller's `:error` clause miss and turned a named form
      # error into a `CaseClauseError` 500 — on a per-keystroke validate.
      [_, y, m, d] ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end

      _other ->
        :error
    end
  end

  defp ordinal_day(n, weekday) when n in -5..5 and n != 0, do: {:ok, {n, weekday}}
  defp ordinal_day(_n, _weekday), do: :error

  defp render_day({nil, weekday}), do: weekday_code(weekday)
  defp render_day({ordinal, weekday}), do: "#{ordinal}#{weekday_code(weekday)}"

  defp weekday_code(number) do
    Enum.find_value(@weekdays, fn {code, n} -> n == number && code end)
  end

  # ── expansion ─────────────────────────────────────────────────────────────

  # Candidate dates as a lazy stream. Each frequency steps by whole calendar
  # units — months and years via `Date.shift/2` so "the 31st, monthly" behaves
  # like a calendar rather than like 30-day arithmetic.
  #
  # `stop_date` is never nil: every entry point takes a window, and the rule's
  # own `UNTIL` can only bring that end *forward*. An unbounded stream here
  # would be an infinite one for `FREQ=DAILY` with no `UNTIL`, so the absence of
  # a nil case is the bound, not an oversight.
  defp candidate_dates(rule, start_date, stop_date) do
    rule
    |> period_starts(start_date)
    |> Stream.take_while(&(Date.compare(&1, stop_date) != :gt))
    |> Stream.flat_map(&dates_in_period(rule, &1))
    |> Stream.filter(&(Date.compare(&1, start_date) != :lt))
    |> Stream.take_while(&(Date.compare(&1, stop_date) != :gt))
  end

  defp period_starts(%{freq: :daily, interval: n}, start_date),
    do: Stream.iterate(start_date, &Date.add(&1, n))

  defp period_starts(%{freq: :weekly, interval: n}, start_date) do
    # From the start of the week containing dtstart, so BYDAY entries earlier in
    # the week than dtstart still fall in the right week.
    week_start = Date.add(start_date, -(Date.day_of_week(start_date) - 1))
    Stream.iterate(week_start, &Date.add(&1, 7 * n))
  end

  defp period_starts(%{freq: :monthly, interval: n}, start_date),
    do: Stream.iterate(Date.beginning_of_month(start_date), &Date.shift(&1, month: n))

  defp period_starts(%{freq: :yearly, interval: n}, start_date),
    do: Stream.iterate(Date.beginning_of_month(start_date), &Date.shift(&1, year: n))

  defp dates_in_period(%{freq: :daily}, date), do: [date]

  defp dates_in_period(%{freq: :weekly, by_day: days}, week_start) do
    days
    |> Enum.map(fn {_ordinal, weekday} -> Date.add(week_start, weekday - 1) end)
    |> Enum.sort(Date)
  end

  defp dates_in_period(%{freq: freq, by_month: [_ | _] = months} = rule, period_start)
       when freq in [:monthly, :yearly] do
    if period_start.month in months,
      do: dates_in_period(%{rule | by_month: []}, period_start),
      else: []
  end

  defp dates_in_period(%{freq: freq} = rule, period_start) when freq in [:monthly, :yearly] do
    days_of_month = Date.days_in_month(period_start)

    by_month_day =
      rule.by_month_day
      |> Enum.map(&if(&1 < 0, do: days_of_month + &1 + 1, else: &1))
      |> Enum.filter(&(&1 in 1..days_of_month))
      |> Enum.map(&%{period_start | day: &1})

    by_day = Enum.flat_map(rule.by_day, &ordinal_weekday(period_start, days_of_month, &1))

    (by_month_day ++ by_day) |> Enum.uniq() |> Enum.sort(Date)
  end

  # `2TU` = the second Tuesday; `-1FR` = the last Friday. A nil ordinal inside a
  # monthly rule means every matching weekday in the month.
  defp ordinal_weekday(period_start, days_of_month, {ordinal, weekday}) do
    matching =
      for day <- 1..days_of_month,
          date = %{period_start | day: day},
          Date.day_of_week(date) == weekday,
          do: date

    case ordinal do
      nil -> matching
      n when n > 0 -> matching |> Enum.at(n - 1) |> List.wrap()
      n -> matching |> Enum.at(length(matching) + n) |> List.wrap()
    end
  end

  # The whole point of carrying a zone: build the local wall time, then convert.
  defp at_local_time(date, time, time_zone) do
    with {:ok, naive} <- NaiveDateTime.new(date, time),
         {:ok, utc} <- resolve_local(naive, time_zone) do
      utc
    else
      _other -> nil
    end
  end

  @doc """
  A local wall time in `time_zone`, as a UTC instant.

  Public because it is the **one** definition of how this codebase resolves a
  DST gap and a DST ambiguity — `KilnCMS.Events.to_utc/2` delegates here rather
  than keeping a second copy. A range and its recurrences disagreeing about what
  "01:30" meant is the bug that would cause.
  """
  @spec to_utc(NaiveDateTime.t(), String.t()) :: {:ok, DateTime.t()} | :error
  def to_utc(naive, time_zone), do: resolve_local(naive, time_zone)

  defp resolve_local(naive, time_zone) do
    case DateTime.from_naive(naive, time_zone) do
      {:ok, dt} ->
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

      # Autumn back: this local time happens twice. The FIRST is the event —
      # "the meeting is at 01:30" means the first one, and taking the later
      # silently moves it an hour.
      {:ambiguous, first, _second} ->
        {:ok, DateTime.shift_zone!(first, "Etc/UTC")}

      # Spring forward: this local time does not exist. Shift past the gap
      # rather than drop the occurrence — an editor with a weekly 01:30 slot
      # expects 52 of them, not 51.
      {:gap, _just_before, just_after} ->
        {:ok, DateTime.shift_zone!(just_after, "Etc/UTC")}

      {:error, _reason} ->
        :error
    end
  end

  defp take_count(stream, nil), do: stream
  defp take_count(stream, count), do: Stream.take(stream, count)

  defp in_window?(datetime, from, until) do
    DateTime.compare(datetime, from) != :lt and DateTime.compare(datetime, until) != :gt
  end

  defp earliest_date(nil, window_end), do: window_end

  defp earliest_date(rule_until, window_end) do
    if Date.compare(rule_until, window_end) == :lt, do: rule_until, else: window_end
  end
end
