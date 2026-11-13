defmodule KilnCMS.Events.RecurrenceTest.RFC do
  @moduledoc false
  # RFC 5545 §3.8.5.3's worked examples, transcribed from the RFC's text: the
  # rule, DTSTART (every example is 09:00 America/New_York) and the dates the
  # RFC lists. A forever rule is checked against the prefix the RFC prints.
  #
  # Two kinds of edit, each named on its row:
  #
  #   * `WKST=SU` dropped where the rule's BYDAY set has no Sunday. Kiln refuses
  #     any week start but Monday (`Recurrence.parse/1`), and with no Sunday in
  #     the set the week start moves no date, so the RFC's dates still hold.
  #   * The RFC's `EXDATE` property is written as Kiln's trailing `EXDATE=` part.
  #
  # The examples Kiln refuses at parse time are in `refused/0`, and the one it
  # expands differently is in `divergent/0`.

  @doc "`{label, rrule, dtstart, expected local dates}`."
  def rows do
    [
      {"daily for 10 occurrences", "FREQ=DAILY;COUNT=10", ~N[1997-09-02 09:00:00],
       d(1997, 9, 2..11)},
      {"every other day, forever", "FREQ=DAILY;INTERVAL=2", ~N[1997-09-02 09:00:00],
       d(1997, 9, 2..30//2) ++
         d(1997, 10, 2..30//2) ++ d(1997, 11, 1..29//2) ++ d(1997, 12, [1, 3])},
      {"every 10 days, 5 occurrences", "FREQ=DAILY;INTERVAL=10;COUNT=5", ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 12, 22]) ++ d(1997, 10, [2, 12])},
      {"every day in January, for 3 years (yearly)",
       "FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA",
       ~N[1998-01-01 09:00:00], d(1998, 1, 1..31) ++ d(1999, 1, 1..31) ++ d(2000, 1, 1..31)},
      {"every day in January, for 3 years (daily)", "FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1",
       ~N[1998-01-01 09:00:00], d(1998, 1, 1..31) ++ d(1999, 1, 1..31) ++ d(2000, 1, 1..31)},
      {"weekly for 10 occurrences", "FREQ=WEEKLY;COUNT=10", ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 9, 16, 23, 30]) ++ d(1997, 10, [7, 14, 21, 28]) ++ d(1997, 11, [4])},
      {"weekly until December 24, 1997", "FREQ=WEEKLY;UNTIL=19971224T000000Z",
       ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 9, 16, 23, 30]) ++
         d(1997, 10, [7, 14, 21, 28]) ++
         d(1997, 11, [4, 11, 18, 25]) ++ d(1997, 12, [2, 9, 16, 23])},
      {"weekly on Tuesday and Thursday for five weeks (WKST=SU dropped)",
       "FREQ=WEEKLY;COUNT=10;BYDAY=TU,TH", ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 4, 9, 11, 16, 18, 23, 25, 30]) ++ d(1997, 10, [2])},
      {"every other week on Tuesday and Thursday, 8 occurrences (WKST=SU dropped)",
       "FREQ=WEEKLY;INTERVAL=2;COUNT=8;BYDAY=TU,TH", ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 4, 16, 18, 30]) ++ d(1997, 10, [2, 14, 16])},
      {"monthly on the first Friday for 10 occurrences", "FREQ=MONTHLY;COUNT=10;BYDAY=1FR",
       ~N[1997-09-05 09:00:00],
       d(1997, 9, [5]) ++
         d(1997, 10, [3]) ++
         d(1997, 11, [7]) ++
         d(1997, 12, [5]) ++
         d(1998, 1, [2]) ++
         d(1998, 2, [6]) ++
         d(1998, 3, [6]) ++ d(1998, 4, [3]) ++ d(1998, 5, [1]) ++ d(1998, 6, [5])},
      {"monthly on the first Friday until December 24, 1997",
       "FREQ=MONTHLY;UNTIL=19971224T000000Z;BYDAY=1FR", ~N[1997-09-05 09:00:00],
       d(1997, 9, [5]) ++ d(1997, 10, [3]) ++ d(1997, 11, [7]) ++ d(1997, 12, [5])},
      {"every other month on the first and last Sunday, 10 occurrences",
       "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU", ~N[1997-09-07 09:00:00],
       d(1997, 9, [7, 28]) ++
         d(1997, 11, [2, 30]) ++
         d(1998, 1, [4, 25]) ++ d(1998, 3, [1, 29]) ++ d(1998, 5, [3, 31])},
      {"monthly on the second-to-last Monday for 6 months", "FREQ=MONTHLY;COUNT=6;BYDAY=-2MO",
       ~N[1997-09-22 09:00:00],
       d(1997, 9, [22]) ++
         d(1997, 10, [20]) ++
         d(1997, 11, [17]) ++ d(1997, 12, [22]) ++ d(1998, 1, [19]) ++ d(1998, 2, [16])},
      {"monthly on the third-to-last day, forever", "FREQ=MONTHLY;BYMONTHDAY=-3",
       ~N[1997-09-28 09:00:00],
       d(1997, 9, [28]) ++
         d(1997, 10, [29]) ++
         d(1997, 11, [28]) ++ d(1997, 12, [29]) ++ d(1998, 1, [29]) ++ d(1998, 2, [26])},
      {"monthly on the 2nd and 15th for 10 occurrences", "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15",
       ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 15]) ++
         d(1997, 10, [2, 15]) ++
         d(1997, 11, [2, 15]) ++ d(1997, 12, [2, 15]) ++ d(1998, 1, [2, 15])},
      {"monthly on the first and last day for 10 occurrences",
       "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1", ~N[1997-09-30 09:00:00],
       d(1997, 9, [30]) ++
         d(1997, 10, [1, 31]) ++
         d(1997, 11, [1, 30]) ++
         d(1997, 12, [1, 31]) ++ d(1998, 1, [1, 31]) ++ d(1998, 2, [1])},
      {"every 18 months on the 10th thru 15th for 10 occurrences",
       "FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15", ~N[1997-09-10 09:00:00],
       d(1997, 9, 10..15) ++ d(1999, 3, 10..13)},
      {"every Tuesday, every other month", "FREQ=MONTHLY;INTERVAL=2;BYDAY=TU",
       ~N[1997-09-02 09:00:00],
       d(1997, 9, [2, 9, 16, 23, 30]) ++
         d(1997, 11, [4, 11, 18, 25]) ++
         d(1998, 1, [6, 13, 20, 27]) ++ d(1998, 3, [3, 10, 17, 24, 31])},
      {"yearly in June and July for 10 occurrences", "FREQ=YEARLY;COUNT=10;BYMONTH=6,7",
       ~N[1997-06-10 09:00:00], for(y <- 1997..2001, m <- [6, 7], do: Date.new!(y, m, 10))},
      {"every other year on January, February and March for 10 occurrences",
       "FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3", ~N[1997-03-10 09:00:00],
       d(1997, 3, [10]) ++
         for(y <- [1999, 2001, 2003], m <- [1, 2, 3], do: Date.new!(y, m, 10))},
      {"every Thursday in March, forever", "FREQ=YEARLY;BYMONTH=3;BYDAY=TH",
       ~N[1997-03-13 09:00:00],
       d(1997, 3, [13, 20, 27]) ++ d(1998, 3, [5, 12, 19, 26]) ++ d(1999, 3, [4, 11, 18, 25])},
      {"every Thursday, but only during June, July and August, forever",
       "FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8", ~N[1997-06-05 09:00:00],
       d(1997, 6, [5, 12, 19, 26]) ++
         d(1997, 7, [3, 10, 17, 24, 31]) ++
         d(1997, 8, [7, 14, 21, 28]) ++
         d(1998, 6, [4, 11, 18, 25]) ++
         d(1998, 7, [2, 9, 16, 23, 30]) ++
         d(1998, 8, [6, 13, 20, 27]) ++
         d(1999, 6, [3, 10, 17, 24]) ++
         d(1999, 7, [1, 8, 15, 22, 29]) ++ d(1999, 8, [5, 12, 19, 26])},
      {"every Friday the 13th, forever (EXDATE as a rule part)",
       "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13;EXDATE=19970902", ~N[1997-09-02 09:00:00],
       d(1998, 2, [13]) ++
         d(1998, 3, [13]) ++
         d(1998, 11, [13]) ++
         d(1999, 8, [13]) ++
         d(2000, 10, [13])},
      {"the first Saturday that follows the first Sunday of the month, forever",
       "FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13", ~N[1997-09-13 09:00:00],
       d(1997, 9, [13]) ++
         d(1997, 10, [11]) ++
         d(1997, 11, [8]) ++
         d(1997, 12, [13]) ++
         d(1998, 1, [10]) ++
         d(1998, 2, [7]) ++
         d(1998, 3, [7]) ++ d(1998, 4, [11]) ++ d(1998, 5, [9]) ++ d(1998, 6, [13])},
      {"every 4 years, US Presidential Election day, forever",
       "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8",
       ~N[1996-11-05 09:00:00], d(1996, 11, [5]) ++ d(2000, 11, [7]) ++ d(2004, 11, [2])},
      {"WKST=MO: every other week on Tuesday and Sunday, 4 occurrences",
       "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO", ~N[1997-08-05 09:00:00],
       d(1997, 8, [5, 10, 19, 24])},
      {"an invalid date (February 30) is ignored", "FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5",
       ~N[2007-01-15 09:00:00], d(2007, 1, [15, 30]) ++ d(2007, 2, [15]) ++ d(2007, 3, [15, 30])}
    ]
  end

  @doc """
  The examples Kiln refuses at parse time, with the part the message names.
  Refused, not ignored: none of these can be in storage.
  """
  def refused do
    [
      {"FREQ=YEARLY;INTERVAL=3;COUNT=10;BYYEARDAY=1,100,200", "BYYEARDAY"},
      # Ordinals stay ±1..5: widening them now would let a rule be saved that
      # an older release, after a rollback, cannot parse.
      {"FREQ=YEARLY;BYDAY=20MO", "1..5"},
      {"FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO", "BYWEEKNO"},
      {"FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", "BYSETPOS"},
      {"FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2", "BYSETPOS"},
      {"FREQ=HOURLY;INTERVAL=3;UNTIL=19970902T170000Z", "HOURLY"},
      {"FREQ=MINUTELY;INTERVAL=15;COUNT=6", "MINUTELY"},
      {"FREQ=DAILY;BYHOUR=9,10,11,12,13,14,15,16;BYMINUTE=0,20,40", "BYHOUR"},
      {"FREQ=WEEKLY;INTERVAL=2;WKST=SU", "WKST"},
      {"FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU", "WKST"}
    ]
  end

  @doc """
  The example Kiln expands differently, with the RFC's dates and Kiln's.

  `UNTIL=19971224T000000Z` is truncated to its date and compared inclusively
  in local time, so Kiln keeps 24 December (09:00 EST, after the UTC instant
  the RFC names). A parse-side follow-up: fixing it needs the zone at cast
  time, or storing UNTIL's value type.
  """
  def divergent do
    rfc = d(1997, 9, 2..30) ++ d(1997, 10, 1..31) ++ d(1997, 11, 1..30) ++ d(1997, 12, 1..23)

    [
      {"daily until December 24, 1997", "FREQ=DAILY;UNTIL=19971224T000000Z",
       ~N[1997-09-02 09:00:00], rfc, rfc ++ [~D[1997-12-24]]}
    ]
  end

  defp d(year, month, days), do: Enum.map(days, &Date.new!(year, month, &1))
end

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
  alias KilnCMS.Events.RecurrenceTest.RFC

  @london "Europe/London"
  @utc "Etc/UTC"
  @new_york "America/New_York"

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

  # Local dates of `rrule` from `dtstart` (UTC wall time) through `through`.
  defp dates(rrule, dtstart, through, opts \\ []) do
    zone = opts[:zone] || @utc

    rrule
    |> rule!()
    |> Recurrence.expand(
      dtstart,
      zone,
      ~U[2000-01-01 00:00:00Z],
      DateTime.new!(through, ~T[23:59:59], "Etc/UTC"),
      max: 1_000
    )
    |> local(zone)
    |> Enum.map(&DateTime.to_date/1)
  end

  describe "yearly rules expand over the year (#2750)" do
    test "BYMONTH=3,9 from March gives March and September every year" do
      assert dates("FREQ=YEARLY;BYMONTH=3,9", ~N[2026-03-10 12:00:00], ~D[2027-12-31]) ==
               [~D[2026-03-10], ~D[2026-09-10], ~D[2027-03-10], ~D[2027-09-10]]
    end

    test "BYMONTH=6;BYMONTHDAY=15 from January is not empty" do
      # The old period was DTSTART's month, January, so this produced nothing,
      # ever. DTSTART itself does not match the rule and is not emitted.
      assert dates("FREQ=YEARLY;BYMONTH=6;BYMONTHDAY=15", ~N[2026-01-10 12:00:00], ~D[2028-12-31]) ==
               [~D[2026-06-15], ~D[2027-06-15], ~D[2028-06-15]]
    end

    test "BYDAY=TU gives every Tuesday of the year, not of one month" do
      tuesdays = dates("FREQ=YEARLY;BYDAY=TU", ~N[2026-01-06 12:00:00], ~D[2026-12-31])

      assert length(tuesdays) == 52
      assert Enum.all?(tuesdays, &(Date.day_of_week(&1) == 2))
      assert tuesdays |> Enum.map(& &1.month) |> Enum.uniq() == Enum.to_list(1..12)
    end

    test "an ordinal BYDAY counts within the year without BYMONTH, the month with it" do
      start = ~N[2026-01-01 12:00:00]

      # Behaviour change: the second Tuesday OF THE YEAR, which is in January —
      # what every calendar client already showed for this rule.
      assert dates("FREQ=YEARLY;BYDAY=2TU", start, ~D[2027-12-31]) ==
               [~D[2026-01-13], ~D[2027-01-12]]

      assert dates("FREQ=YEARLY;BYMONTH=6;BYDAY=2TU", start, ~D[2027-12-31]) ==
               [~D[2026-06-09], ~D[2027-06-08]]

      assert dates("FREQ=YEARLY;BYDAY=-1FR", start, ~D[2027-12-31]) ==
               [~D[2026-12-25], ~D[2027-12-31]]

      # Thanksgiving.
      assert dates("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", start, ~D[2027-12-31]) ==
               [~D[2026-11-26], ~D[2027-11-25]]
    end

    test "BYMONTHDAY without BYMONTH is every month of the year" do
      start = ~N[2026-01-01 12:00:00]

      firsts = dates("FREQ=YEARLY;BYMONTHDAY=1", start, ~D[2026-12-31])
      assert firsts == Enum.map(1..12, &Date.new!(2026, &1, 1))

      lasts = dates("FREQ=YEARLY;BYMONTHDAY=-1", start, ~D[2026-12-31])
      assert lasts == Enum.map(1..12, &Date.end_of_month(Date.new!(2026, &1, 1)))
    end

    test "29 February: invalid dates are skipped, not rolled over, and COUNT counts real ones" do
      assert dates("FREQ=YEARLY", ~N[2028-02-29 12:00:00], ~D[2037-12-31]) ==
               [~D[2028-02-29], ~D[2032-02-29], ~D[2036-02-29]]

      assert dates("FREQ=YEARLY;COUNT=3", ~N[2028-02-29 12:00:00], ~D[2099-12-31]) ==
               [~D[2028-02-29], ~D[2032-02-29], ~D[2036-02-29]]

      assert dates("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1", ~N[2027-02-28 12:00:00], ~D[2029-12-31]) ==
               [~D[2027-02-28], ~D[2028-02-29], ~D[2029-02-28]]

      # BYMONTHDAY defaults to DTSTART's 31st, which February does not have.
      assert dates("FREQ=YEARLY;BYMONTH=1,2", ~N[2026-01-31 12:00:00], ~D[2027-12-31]) ==
               [~D[2026-01-31], ~D[2027-01-31]]
    end

    test "COUNT, UNTIL, EXDATE and INTERVAL apply to yearly rules" do
      start = ~N[2026-03-10 12:00:00]

      assert dates("FREQ=YEARLY;BYMONTH=3,9;COUNT=3", start, ~D[2099-12-31]) ==
               [~D[2026-03-10], ~D[2026-09-10], ~D[2027-03-10]]

      # UNTIL is an inclusive local date.
      assert dates("FREQ=YEARLY;BYMONTH=3,9;UNTIL=20270310", start, ~D[2099-12-31]) ==
               [~D[2026-03-10], ~D[2026-09-10], ~D[2027-03-10]]

      # EXDATE after COUNT: the cancelled date is not backfilled from the tail.
      assert dates("FREQ=YEARLY;BYMONTH=3,9;COUNT=4;EXDATE=20260910", start, ~D[2099-12-31]) ==
               [~D[2026-03-10], ~D[2027-03-10], ~D[2027-09-10]]

      assert dates("FREQ=YEARLY;INTERVAL=2;BYMONTH=3,9", start, ~D[2028-12-31]) ==
               [~D[2026-03-10], ~D[2026-09-10], ~D[2028-03-10], ~D[2028-09-10]]
    end

    test "keeps the local wall time across DST" do
      instants =
        "FREQ=YEARLY;BYMONTH=3,7"
        |> rule!()
        |> Recurrence.expand(
          ~N[2026-03-01 09:00:00],
          @new_york,
          ~U[2026-01-01 00:00:00Z],
          ~U[2026-12-31 00:00:00Z]
        )

      assert Enum.map(local(instants), &DateTime.to_naive/1) ==
               [~N[2026-03-01 09:00:00], ~N[2026-07-01 09:00:00]]

      # EST, then EDT: the instant moves and the wall clock does not.
      assert Enum.map(instants, & &1.hour) == [14, 13]
    end

    test "a rule no date can satisfy returns nothing, within the window" do
      rule = rule!("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30")

      assert [] ==
               Recurrence.expand(
                 rule,
                 ~N[2026-01-01 12:00:00],
                 @utc,
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2126-01-01 00:00:00Z]
               )

      assert is_nil(
               Recurrence.next_occurrence(
                 rule,
                 ~N[2026-01-01 12:00:00],
                 @utc,
                 ~U[2026-01-01 00:00:00Z],
                 horizon_days: 36_600
               )
             )
    end
  end

  describe "BYMONTH limits DAILY and WEEKLY too" do
    test "DAILY;BYMONTH=6 is June only" do
      june = dates("FREQ=DAILY;BYMONTH=6", ~N[2026-05-30 12:00:00], ~D[2026-12-31])
      assert june == Enum.map(1..30, &Date.new!(2026, 6, &1))
    end

    test "WEEKLY;BYDAY=MO;BYMONTH=6 is the Mondays of June" do
      assert dates("FREQ=WEEKLY;BYDAY=MO;BYMONTH=6", ~N[2026-05-04 12:00:00], ~D[2026-12-31]) ==
               [~D[2026-06-01], ~D[2026-06-08], ~D[2026-06-15], ~D[2026-06-22], ~D[2026-06-29]]
    end
  end

  describe "BYDAY limits BYMONTHDAY rather than adding to it" do
    test "MONTHLY;BYDAY=FR;BYMONTHDAY=13 is Friday the 13th, not every Friday and 13th" do
      assert dates("FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", ~N[2026-01-01 12:00:00], ~D[2026-12-31]) ==
               [~D[2026-02-13], ~D[2026-03-13], ~D[2026-11-13]]
    end
  end

  describe "the accept set is unchanged" do
    test "every combination the expansion now honours still parses" do
      # None of these may become a parse error: a stored rule that stops
      # parsing renders as a one-off event, silently.
      for rrule <-
            ~w(FREQ=YEARLY;BYDAY=2TU FREQ=YEARLY;BYMONTH=11;BYDAY=4TH FREQ=YEARLY;BYMONTHDAY=-1
               FREQ=YEARLY;BYMONTH=3,9 FREQ=DAILY;BYMONTH=6 FREQ=WEEKLY;BYMONTH=6;BYDAY=MO
               FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13 FREQ=YEARLY;BYDAY=-5SU) do
        assert {:ok, _} = Recurrence.parse(rrule), rrule
      end
    end

    test "an ordinal past ±5 names the range" do
      assert {:error, message} = Recurrence.parse("FREQ=YEARLY;BYDAY=20MO")
      assert message =~ "1..5"
      assert {:error, message} = Recurrence.parse("FREQ=MONTHLY;BYDAY=0TU")
      assert message =~ "1..5"
    end

    test "to_rrule/2 re-emits these rules byte for byte, so storage does not move" do
      for rrule <-
            ~w(FREQ=YEARLY;BYMONTH=3,9 FREQ=YEARLY;BYMONTH=11;BYDAY=4TH
               FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13) do
        assert rrule |> rule!() |> Recurrence.to_rrule() == rrule
      end
    end
  end

  # Every RFC example at 09:00 New York, inside a window wide enough for all of
  # them, capped at the number of dates the RFC prints.
  defp rfc_expand(rrule, dtstart, count) do
    rrule
    |> rule!()
    |> Recurrence.expand(
      dtstart,
      @new_york,
      ~U[1990-01-01 00:00:00Z],
      ~U[2010-01-01 00:00:00Z],
      max: count
    )
  end

  defp local(instants, zone \\ @new_york),
    do: Enum.map(instants, &DateTime.shift_zone!(&1, zone))

  describe "RFC 5545 §3.8.5.3 examples" do
    for {label, rrule, dtstart, expected} <- RFC.rows() do
      test label do
        expected = unquote(Macro.escape(expected))

        actual =
          unquote(rrule)
          |> rfc_expand(unquote(Macro.escape(dtstart)), length(expected))
          |> local()

        assert Enum.map(actual, &DateTime.to_date/1) == expected
        # Wall clock: 09:00 local on both sides of every DST change in range.
        assert Enum.all?(actual, &(DateTime.to_time(&1) == ~T[09:00:00]))
      end
    end

    for {rrule, part} <- RFC.refused() do
      test "refuses #{rrule}, naming #{part}" do
        assert {:error, message} = Recurrence.parse(unquote(rrule))
        assert message =~ unquote(part)
      end
    end

    # A known divergence, not a pass: the RFC's dates are kept in the row so
    # the follow-up that fixes the parse side can flip this to `rfc`.
    @tag :rfc_divergence
    for {label, rrule, dtstart, _rfc, kiln} <- RFC.divergent() do
      test "diverges: #{label} (UNTIL=…T000000Z is read as an inclusive local date)" do
        kiln = unquote(Macro.escape(kiln))
        actual = unquote(rrule) |> rfc_expand(unquote(Macro.escape(dtstart)), 1_000) |> local()

        assert Enum.map(actual, &DateTime.to_date/1) == kiln
      end
    end
  end

  describe "engine_version/0 moves with the expansion" do
    # `next_occurrence_at` is stored, and `BackfillWorker` recomputes it on boot
    # only when `engine_version/0` changes. An expansion change that does not
    # bump it leaves every stored value the old engine computed in place, so
    # this checksums the expansion of a fixed corpus (the RFC table) per
    # engine. Changing the expansion fails here: bump `@engine_version` in
    # `Recurrence` and add the new checksum, never edit an existing one.
    @golden %{
      1 => "9465c18581c8b39f31c897988ddd0d74cd31c3ce1308c53af7f9b0796a602217",
      2 => "1590d90fca061d5d67188b30cb61cec8cbef56b09bb206a3c6285d97eaa5b50a"
    }

    test "the corpus checksum is the one recorded for this engine" do
      assert Map.fetch(@golden, Recurrence.engine_version()) == {:ok, corpus_checksum()},
             "expansion output changed: bump Recurrence's @engine_version and record " <>
               "#{corpus_checksum()} for the new version"
    end
  end

  defp corpus_checksum do
    corpus =
      Enum.map(RFC.rows(), fn {_label, rrule, dtstart, expected} ->
        {rrule, dtstart, length(expected)}
      end) ++
        Enum.map(RFC.divergent(), fn {_label, rrule, dtstart, _rfc, kiln} ->
          {rrule, dtstart, length(kiln) + 5}
        end)

    corpus
    |> Enum.map_join("\n", fn {rrule, dtstart, count} ->
      instants = rrule |> rfc_expand(dtstart, count) |> Enum.map_join(",", &DateTime.to_iso8601/1)
      rrule <> "|" <> NaiveDateTime.to_iso8601(dtstart) <> "|" <> instants
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
