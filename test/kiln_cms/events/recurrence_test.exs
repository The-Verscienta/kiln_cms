defmodule KilnCMS.Events.RecurrenceTest do
  @moduledoc """
  The RRULE subset and its bounded expansion (#480).

  Two things get most of the attention here: that expansion is *bounded* even
  for rules an editor can legally type, and that it is *wall-clock* — a weekly
  19:00 slot stays 19:00 across a DST boundary, which is the whole reason the
  project now carries a timezone database.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Events.Recurrence

  @london "Europe/London"
  @utc "Etc/UTC"

  defp rule!(rrule) do
    {:ok, rule} = Recurrence.parse(rrule)
    rule
  end

  defp expand(rrule, dtstart, from, until, opts \\ []) do
    Recurrence.expand(rule!(rrule), dtstart, opts[:zone] || @utc, from, until, opts)
  end

  defp utc(iso), do: iso |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

  describe "parse/1" do
    test "reads the supported subset" do
      assert {:ok, rule} = Recurrence.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20260301")
      assert rule.freq == :weekly
      assert rule.interval == 2
      assert rule.by_day == [{nil, 2}, {nil, 4}]
      assert rule.until == ~D[2026-03-01]
    end

    test "tolerates the RRULE: prefix and lowercase" do
      assert {:ok, %{freq: :daily}} = Recurrence.parse("rrule:freq=daily")
    end

    test "reads an ordinal BYDAY for monthly rules" do
      assert {:ok, %{by_day: [{2, 2}]}} = Recurrence.parse("FREQ=MONTHLY;BYDAY=2TU")
      assert {:ok, %{by_day: [{-1, 5}]}} = Recurrence.parse("FREQ=MONTHLY;BYDAY=-1FR")
    end

    test "rejects rather than silently ignores what it cannot honour" do
      # An editor whose rule is quietly reinterpreted gets a calendar that is
      # wrong in a way nothing surfaces. Better to refuse at the form.
      for part <- ~w(BYSETPOS=1 BYWEEKNO=3 BYYEARDAY=100 BYHOUR=9) do
        assert {:error, message} = Recurrence.parse("FREQ=WEEKLY;#{part}")
        assert message =~ String.replace(part, ~r/=.*/, "")
      end

      assert {:error, message} = Recurrence.parse("FREQ=SECONDLY")
      assert message =~ "SECONDLY"
    end

    test "rejects a rule with no FREQ, and COUNT with UNTIL" do
      assert {:error, message} = Recurrence.parse("INTERVAL=2")
      assert message =~ "FREQ"

      assert {:error, message} = Recurrence.parse("FREQ=DAILY;COUNT=5;UNTIL=20260301")
      assert message =~ "not both"
    end

    test "rejects an ordinal BYDAY on a weekly rule" do
      # `2TU` means "the second Tuesday of the month" — meaningless weekly, and
      # honouring it as a plain TU would be the silent reinterpretation above.
      assert {:error, message} = Recurrence.parse("FREQ=WEEKLY;BYDAY=2TU")
      assert message =~ "MONTHLY"
    end

    test "rejects malformed numbers and dates with a message naming the part" do
      assert {:error, m} = Recurrence.parse("FREQ=DAILY;INTERVAL=0")
      assert m =~ "INTERVAL"
      assert {:error, m} = Recurrence.parse("FREQ=DAILY;COUNT=-1")
      assert m =~ "COUNT"
      assert {:error, m} = Recurrence.parse("FREQ=DAILY;UNTIL=nope")
      assert m =~ "UNTIL"
      assert {:error, m} = Recurrence.parse("FREQ=MONTHLY;BYMONTHDAY=45")
      assert m =~ "BYMONTHDAY"
    end

    test "round-trips through to_rrule/1" do
      for rrule <- [
            "FREQ=DAILY",
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH",
            "FREQ=MONTHLY;BYDAY=2TU",
            "FREQ=MONTHLY;BYMONTHDAY=1,-1",
            "FREQ=YEARLY;COUNT=5"
          ] do
        assert rrule |> rule!() |> Recurrence.to_rrule() == rrule
      end
    end
  end

  describe "expansion is bounded" do
    test "a rule with no end returns at most :max, not everything" do
      # `FREQ=DAILY` with no COUNT or UNTIL over a decade is a legal rule an
      # editor can type. Expanding it unbounded is a denial of service.
      occurrences =
        expand(
          "FREQ=DAILY",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2036-01-01T00:00:00"),
          max: 10
        )

      assert length(occurrences) == 10
    end

    test ":max cannot exceed the hard ceiling, whatever a caller asks for" do
      occurrences =
        expand(
          "FREQ=DAILY",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2126-01-01T00:00:00"),
          max: 10_000_000
        )

      assert length(occurrences) <= 1_000
    end

    test "a far-future UNTIL costs nothing when the window is small" do
      # The rule's UNTIL and the caller's window are both ceilings; walking to
      # the earlier of them is what stops `UNTIL=99991231` from being a trap.
      occurrences =
        expand(
          "FREQ=DAILY;UNTIL=99991231",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-01-05T23:59:59")
        )

      assert length(occurrences) == 5
    end
  end

  describe "frequencies" do
    test "daily with an interval" do
      occurrences =
        expand(
          "FREQ=DAILY;INTERVAL=3",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-01-10T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-01], ~D[2026-01-04], ~D[2026-01-07], ~D[2026-01-10]]
    end

    test "weekly with no BYDAY recurs on DTSTART's own weekday" do
      # RFC 5545's default. Getting this wrong silently moves every weekly event
      # to Monday.
      occurrences =
        expand(
          "FREQ=WEEKLY",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-01-29T23:59:59")
        )

      # 2026-01-01 is a Thursday.
      assert Enum.map(occurrences, &Date.day_of_week(DateTime.to_date(&1))) == [4, 4, 4, 4, 4]
    end

    test "weekly on several days, every other week" do
      occurrences =
        expand(
          "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
          ~N[2026-01-05 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-02-01T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-05], ~D[2026-01-07], ~D[2026-01-19], ~D[2026-01-21]]
    end

    test "monthly on an ordinal weekday" do
      occurrences =
        expand(
          "FREQ=MONTHLY;BYDAY=2TU",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-04-30T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-13], ~D[2026-02-10], ~D[2026-03-10], ~D[2026-04-14]]
    end

    test "monthly on the last day, across months of different lengths" do
      occurrences =
        expand(
          "FREQ=MONTHLY;BYMONTHDAY=-1",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-04-30T23:59:59")
        )

      # February is what catches naive 30-day arithmetic.
      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-31], ~D[2026-02-28], ~D[2026-03-31], ~D[2026-04-30]]
    end

    test "monthly on the 31st simply skips months that have none" do
      occurrences =
        expand(
          "FREQ=MONTHLY;BYMONTHDAY=31",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-06-30T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-31], ~D[2026-03-31], ~D[2026-05-31]]
    end

    test "monthly with no BYDAY or BYMONTHDAY recurs on DTSTART's day" do
      # RFC 5545's other default, and the twin of the weekly case above. Getting
      # it wrong silently moves every monthly event to the 1st.
      occurrences =
        expand(
          "FREQ=MONTHLY",
          ~N[2026-01-15 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-04-30T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-15], ~D[2026-02-15], ~D[2026-03-15], ~D[2026-04-15]]
    end

    test "yearly" do
      occurrences =
        expand(
          "FREQ=YEARLY",
          ~N[2026-03-15 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2029-12-31T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-03-15], ~D[2027-03-15], ~D[2028-03-15], ~D[2029-03-15]]
    end
  end

  describe "COUNT, UNTIL and EXDATE" do
    test "COUNT is counted from the series start, not from the window" do
      # A window into the middle of a COUNT=5 series must not report five more.
      occurrences =
        expand(
          "FREQ=DAILY;COUNT=5",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-03T00:00:00"),
          utc("2026-12-31T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-03], ~D[2026-01-04], ~D[2026-01-05]]
    end

    test "UNTIL ends the series" do
      occurrences =
        expand(
          "FREQ=DAILY;UNTIL=20260103",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-12-31T23:59:59")
        )

      assert length(occurrences) == 3
    end

    test "EXDATE removes occurrences without shifting the rest" do
      occurrences =
        expand(
          "FREQ=DAILY;EXDATE=20260102,20260104",
          ~N[2026-01-01 09:00:00],
          utc("2026-01-01T00:00:00"),
          utc("2026-01-05T23:59:59")
        )

      assert Enum.map(occurrences, &DateTime.to_date/1) ==
               [~D[2026-01-01], ~D[2026-01-03], ~D[2026-01-05]]
    end
  end

  describe "wall-clock across DST" do
    test "a weekly evening slot keeps its local time through spring forward" do
      # 2026-03-29 is the UK spring-forward. A UTC-arithmetic expansion would
      # drift this to 18:00 local after the transition.
      occurrences =
        expand(
          "FREQ=WEEKLY;BYDAY=SU",
          ~N[2026-03-22 19:00:00],
          utc("2026-03-01T00:00:00"),
          utc("2026-04-15T00:00:00"),
          zone: @london
        )

      local_times =
        Enum.map(occurrences, fn dt ->
          dt |> DateTime.shift_zone!(@london) |> DateTime.to_time()
        end)

      assert Enum.uniq(local_times) == [~T[19:00:00]]

      # …and the underlying UTC instants really did move, which is the point.
      assert Enum.map(occurrences, &DateTime.to_time/1) |> Enum.uniq() |> length() == 2
    end

    test "an occurrence in the spring-forward gap is shifted, not dropped" do
      # 01:30 does not exist on 2026-03-29 in London. An editor with a weekly
      # 01:30 slot expects 52 of them, not 51.
      occurrences =
        expand(
          "FREQ=WEEKLY;BYDAY=SU",
          ~N[2026-03-22 01:30:00],
          utc("2026-03-01T00:00:00"),
          utc("2026-04-05T00:00:00"),
          zone: @london
        )

      dates = Enum.map(occurrences, &(&1 |> DateTime.shift_zone!(@london) |> DateTime.to_date()))
      assert ~D[2026-03-29] in dates
    end

    test "an ambiguous autumn-back time resolves to the first, deterministically" do
      # 01:30 happens twice on 2026-10-25 in London. "The meeting is at 01:30"
      # means the first one; picking the later silently moves it an hour.
      [occurrence] =
        expand(
          "FREQ=DAILY;COUNT=1",
          ~N[2026-10-25 01:30:00],
          utc("2026-10-25T00:00:00"),
          utc("2026-10-26T00:00:00"),
          zone: @london
        )

      # BST is UTC+1, so the first 01:30 local is 00:30 UTC.
      assert DateTime.to_time(occurrence) == ~T[00:30:00]
    end
  end

  describe "next_occurrence/5" do
    test "finds the next one at or after a moment" do
      rule = rule!("FREQ=WEEKLY;BYDAY=TU")

      next =
        Recurrence.next_occurrence(
          rule,
          ~N[2026-01-06 09:00:00],
          @utc,
          utc("2026-01-10T00:00:00")
        )

      assert DateTime.to_date(next) == ~D[2026-01-13]
    end

    test "nil when the series has ended" do
      rule = rule!("FREQ=DAILY;COUNT=2")

      refute Recurrence.next_occurrence(
               rule,
               ~N[2026-01-01 09:00:00],
               @utc,
               utc("2026-06-01T00:00:00")
             )
    end

    test "nil rather than an unbounded search when nothing falls in the horizon" do
      rule = rule!("FREQ=YEARLY")

      refute Recurrence.next_occurrence(
               rule,
               ~N[2026-01-01 09:00:00],
               @utc,
               utc("2026-02-01T00:00:00"),
               horizon_days: 10
             )
    end
  end

  describe "parts a frequency cannot honour are refused, not ignored" do
    test "BYDAY with DAILY" do
      # It used to save, expand to every day, and re-emit BYDAY to the client —
      # two different calendars from one rule, with nothing to tell an editor.
      assert {:error, message} = Recurrence.parse("FREQ=DAILY;BYDAY=MO,WE,FR")
      assert message =~ "BYDAY"
    end

    test "BYMONTHDAY with DAILY or WEEKLY" do
      assert {:error, _} = Recurrence.parse("FREQ=DAILY;BYMONTHDAY=1")
      assert {:error, _} = Recurrence.parse("FREQ=WEEKLY;BYMONTHDAY=1")
    end

    test "an ordinal BYDAY anywhere in the list, not just at its head" do
      assert {:error, message} = Recurrence.parse("FREQ=WEEKLY;BYDAY=MO,2TU")
      assert message =~ "ordinal"
    end

    test "an ordinal of zero, or one no month can satisfy" do
      assert {:error, _} = Recurrence.parse("FREQ=MONTHLY;BYDAY=0TU")
      # -6TU used to reach `Enum.at/2`, whose negative indexing counts from the
      # end — silently becoming some other Tuesday rather than none.
      assert {:error, _} = Recurrence.parse("FREQ=MONTHLY;BYDAY=-6TU")
      assert {:ok, _} = Recurrence.parse("FREQ=MONTHLY;BYDAY=-1FR")
    end

    test "a week start this module does not actually honour" do
      assert {:ok, _} = Recurrence.parse("FREQ=WEEKLY;BYDAY=SU;WKST=MO")
      assert {:error, message} = Recurrence.parse("FREQ=WEEKLY;BYDAY=SU;WKST=SU")
      assert message =~ "Monday"
    end

    test "an impossible date is a form error, not a crash" do
      # `Date.new/3` answers `{:error, :invalid_date}`, which no caller matched.
      assert {:error, message} = Recurrence.parse("FREQ=DAILY;UNTIL=20260230")
      assert message =~ "UNTIL"
      assert {:error, _} = Recurrence.parse("FREQ=DAILY;EXDATE=20260431")
    end
  end

  describe "BYMONTH" do
    test "is supported, as the docs say" do
      assert {:ok, rule} = Recurrence.parse("FREQ=MONTHLY;BYMONTHDAY=15;BYMONTH=3,6")
      assert rule.by_month == [3, 6]
      assert Recurrence.to_rrule(rule) =~ "BYMONTH=3,6"
    end

    test "restricts expansion to those months" do
      {:ok, rule} = Recurrence.parse("FREQ=MONTHLY;BYMONTHDAY=15;BYMONTH=3,6")

      months =
        rule
        |> Recurrence.expand(
          ~N[2026-01-15 12:00:00],
          "Etc/UTC",
          ~U[2026-01-01 00:00:00Z],
          ~U[2026-12-31 00:00:00Z]
        )
        |> Enum.map(&(&1 |> DateTime.to_date() |> Map.fetch!(:month)))

      assert months == [3, 6]
    end
  end

  describe "EXDATE is subtracted after COUNT, per RFC 5545" do
    test "a skipped date does not backfill from the tail" do
      {:ok, rule} = Recurrence.parse("FREQ=DAILY;COUNT=10;EXDATE=20260303")

      dates =
        rule
        |> Recurrence.expand(
          ~N[2026-03-01 19:00:00],
          "Etc/UTC",
          ~U[2026-01-01 00:00:00Z],
          ~U[2027-01-01 00:00:00Z]
        )
        |> Enum.map(&DateTime.to_date/1)

      # Nine, ending on the 10th — COUNT generates the set, EXDATE subtracts
      # from it. Rejecting first gave ten ending on the 11th, so the site
      # advertised a date no subscribed client had.
      assert length(dates) == 9
      assert List.last(dates) == ~D[2026-03-10]
      refute ~D[2026-03-03] in dates
    end
  end

  describe "UNTIL renders against DTSTART's value type" do
    test "date form for storage, UTC datetime form for a timed event" do
      {:ok, rule} = Recurrence.parse("FREQ=WEEKLY;BYDAY=TU;UNTIL=20260303")

      assert Recurrence.to_rrule(rule) =~ "UNTIL=20260303"
      # End-of-day, because the stored UNTIL is an inclusive date: midnight
      # would silently drop 3 March, which Kiln's own expansion keeps.
      assert Recurrence.to_rrule(rule, until: :datetime) =~ "UNTIL=20260303T235959Z"
    end
  end
end
