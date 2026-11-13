defmodule KilnCMS.Backups.ScheduleWindowTest do
  @moduledoc """
  A backup schedule's windows (part of #2219), computed by
  `KilnCMS.Backups.Schedule.Window`: per interval, across DST transitions and
  odd offsets, at the ends of months, and with the baseline and last claimed
  window deciding what is due.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Schedule.Window
  alias KilnCMS.Types.UnknownAtom

  defp s(attrs) do
    Map.merge(
      %{
        interval: :daily,
        time_of_day: ~T[03:00:00],
        starts_on: ~D[2026-01-01],
        time_zone: "Etc/UTC",
        baseline_at: ~U[2026-01-01 00:00:00.000000Z],
        last_window_at: nil,
        components: [:db]
      },
      Map.new(attrs)
    )
  end

  defp latest(s, now), do: ok!(Window.latest(s, now))
  defp next(s, now), do: ok!(Window.next(s, now))
  defp previous(s, w), do: ok!(Window.previous(s, w))
  defp due(s, now), do: ok!(Window.due(s, now))

  defp ok!({:ok, value}), do: value

  defp occurrences(s, from, to) do
    {:ok, list} = Window.occurrences(s, from, to)
    list
  end

  defp gaps_in_hours(list) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :hour) end)
  end

  describe "latest, next and previous" do
    test "daily" do
      s = s(interval: :daily)
      now = ~U[2026-03-10 12:00:00Z]

      assert latest(s, now) == ~U[2026-03-10 03:00:00.000000Z]
      assert next(s, now) == ~U[2026-03-11 03:00:00.000000Z]
      assert previous(s, ~U[2026-03-10 03:00:00.000000Z]) == ~U[2026-03-09 03:00:00.000000Z]
    end

    test "every 2, 4, 8 and 12 hours" do
      now = ~U[2026-03-10 12:30:00Z]

      for {interval, latest, next} <- [
            {:every_2h, ~U[2026-03-10 11:00:00.000000Z], ~U[2026-03-10 13:00:00.000000Z]},
            {:every_4h, ~U[2026-03-10 11:00:00.000000Z], ~U[2026-03-10 15:00:00.000000Z]},
            {:every_8h, ~U[2026-03-10 11:00:00.000000Z], ~U[2026-03-10 19:00:00.000000Z]},
            {:every_12h, ~U[2026-03-10 03:00:00.000000Z], ~U[2026-03-10 15:00:00.000000Z]}
          ] do
        s = s(interval: interval)
        assert latest(s, now) == latest, "latest #{interval}"
        assert next(s, now) == next, "next #{interval}"
      end
    end

    test "weekly fires on starts_on's weekday" do
      # 2026-01-01 is a Thursday.
      s = s(interval: :weekly)
      now = ~U[2026-03-10 12:00:00Z]

      assert latest(s, now) == ~U[2026-03-05 03:00:00.000000Z]
      assert next(s, now) == ~U[2026-03-12 03:00:00.000000Z]
      assert previous(s, ~U[2026-03-05 03:00:00.000000Z]) == ~U[2026-02-26 03:00:00.000000Z]
    end

    test "fortnightly keeps starts_on's week parity" do
      s = s(interval: :fortnightly)

      assert occurrences(s, ~D[2026-01-01], ~D[2026-02-28]) == [
               ~U[2026-01-01 03:00:00.000000Z],
               ~U[2026-01-15 03:00:00.000000Z],
               ~U[2026-01-29 03:00:00.000000Z],
               ~U[2026-02-12 03:00:00.000000Z],
               ~U[2026-02-26 03:00:00.000000Z]
             ]

      assert latest(s, ~U[2026-02-25 12:00:00Z]) == ~U[2026-02-12 03:00:00.000000Z]
      assert next(s, ~U[2026-02-13 12:00:00Z]) == ~U[2026-02-26 03:00:00.000000Z]
    end

    test "monthly on the 31st clamps to February's end, in a leap year too" do
      s = s(interval: :monthly, starts_on: ~D[2026-01-31])

      assert occurrences(s, ~D[2026-01-01], ~D[2026-04-30]) == [
               ~U[2026-01-31 03:00:00.000000Z],
               ~U[2026-02-28 03:00:00.000000Z],
               ~U[2026-03-31 03:00:00.000000Z],
               ~U[2026-04-30 03:00:00.000000Z]
             ]

      leap = s(interval: :monthly, starts_on: ~D[2028-01-31], baseline_at: nil)
      assert next(leap, ~U[2028-02-01 00:00:00Z]) == ~U[2028-02-29 03:00:00.000000Z]
      assert latest(leap, ~U[2028-03-15 00:00:00Z]) == ~U[2028-02-29 03:00:00.000000Z]
    end

    test "starts_on in the future: no latest, and next is the first occurrence" do
      s = s(starts_on: ~D[2026-06-01])

      assert latest(s, ~U[2026-03-10 12:00:00Z]) == nil
      assert due(s, ~U[2026-03-10 12:00:00Z]) == nil
      assert next(s, ~U[2026-03-10 12:00:00Z]) == ~U[2026-06-01 03:00:00.000000Z]
    end

    test "latest exactly at the occurrence minute, and one second before" do
      s = s([])

      assert latest(s, ~U[2026-03-10 03:00:00Z]) == ~U[2026-03-10 03:00:00.000000Z]
      assert latest(s, ~U[2026-03-10 02:59:59Z]) == ~U[2026-03-09 03:00:00.000000Z]
    end
  end

  describe "DST and offsets" do
    test "Europe/Paris spring-forward, daily 02:30: one occurrence, at 03:00 local" do
      s = s(time_of_day: ~T[02:30:00], time_zone: "Europe/Paris")

      # 2026-03-29 02:00 CET jumps to 03:00 CEST.
      assert occurrences(s, ~D[2026-03-28], ~D[2026-03-30]) == [
               ~U[2026-03-28 01:30:00.000000Z],
               # 03:00 CEST
               ~U[2026-03-29 01:00:00.000000Z],
               ~U[2026-03-30 00:30:00.000000Z]
             ]
    end

    test "fall-back, daily 01:30: one occurrence, the first instant" do
      # 2026-11-01 02:00 EDT falls back to 01:00 EST; 01:30 happens twice.
      s = s(time_of_day: ~T[01:30:00], time_zone: "America/New_York")

      assert occurrences(s, ~D[2026-10-31], ~D[2026-11-02]) == [
               ~U[2026-10-31 05:30:00.000000Z],
               # 01:30 EDT, not 01:30 EST (06:30Z)
               ~U[2026-11-01 05:30:00.000000Z],
               ~U[2026-11-02 06:30:00.000000Z]
             ]

      # The second 01:30 is never a window: right after it, the latest is
      # still the first.
      assert latest(s, ~U[2026-11-01 06:45:00Z]) == ~U[2026-11-01 05:30:00.000000Z]
    end

    test "America/New_York every 2 h across both transitions: strictly increasing, no duplicates" do
      s = s(interval: :every_2h, time_of_day: ~T[00:00:00], time_zone: "America/New_York")

      for {from, to} <- [{~D[2026-03-07], ~D[2026-03-09]}, {~D[2026-10-31], ~D[2026-11-02]}] do
        list = occurrences(s, from, to)
        assert list == Enum.uniq(list)
        assert Enum.all?(gaps_in_hours(list), &(&1 in 1..3)), inspect(gaps_in_hours(list))
        assert Enum.sort(list, DateTime) == list
      end

      # The spring-forward day: 02:00 does not exist and fires at 03:00, an
      # hour before 04:00.
      spring = occurrences(s, ~D[2026-03-08], ~D[2026-03-08])
      assert length(spring) == 12
      assert 1 in gaps_in_hours(spring)
    end

    test "Pacific/Chatham and Asia/Kolkata offsets" do
      chatham = s(time_zone: "Pacific/Chatham")
      # +13:45 in March (daylight time).
      assert latest(chatham, ~U[2026-03-10 12:00:00Z]) == ~U[2026-03-09 13:15:00.000000Z]

      kolkata = s(time_zone: "Asia/Kolkata")
      assert latest(kolkata, ~U[2026-03-10 12:00:00Z]) == ~U[2026-03-09 21:30:00.000000Z]
    end
  end

  describe "due/2" do
    test "honors baseline_at and last_window_at" do
      now = ~U[2026-03-10 12:00:00Z]
      w = ~U[2026-03-10 03:00:00.000000Z]

      assert due(s([]), now) == w
      # Rebaselined after today's window: nothing until tomorrow.
      assert due(s(baseline_at: ~U[2026-03-10 04:00:00Z]), now) == nil

      assert next(s(baseline_at: ~U[2026-03-10 04:00:00Z]), now) ==
               ~U[2026-03-11 03:00:00.000000Z]

      # Already claimed.
      assert due(s(last_window_at: w), now) == nil
      # Claimed yesterday's: today's is due.
      assert due(s(last_window_at: ~U[2026-03-09 03:00:00.000000Z]), now) == w
    end

    test "next never falls before the baseline" do
      s = s(baseline_at: ~U[2026-03-12 00:00:00Z])
      assert next(s, ~U[2026-03-10 12:00:00Z]) == ~U[2026-03-12 03:00:00.000000Z]
    end
  end

  describe "missed?/2" do
    test "after three days of downtime" do
      w = ~U[2026-03-10 03:00:00.000000Z]
      s = s(last_window_at: ~U[2026-03-07 03:00:00.000000Z])

      assert due(s, ~U[2026-03-10 12:00:00Z]) == w
      assert Window.missed?(s, w)
      refute Window.missed?(s(last_window_at: ~U[2026-03-09 03:00:00.000000Z]), w)
      refute Window.missed?(s(last_window_at: nil), w)
    end

    # D5: windows before the baseline were never owed.
    test "a resumed (rebaselined) daily schedule misses nothing" do
      w = ~U[2026-03-10 03:00:00.000000Z]

      s =
        s(
          last_window_at: ~U[2026-03-01 03:00:00.000000Z],
          baseline_at: ~U[2026-03-09 10:00:00.000000Z]
        )

      assert due(s, ~U[2026-03-10 12:00:00Z]) == w
      refute Window.missed?(s, w)
    end
  end

  describe "invalid schedules" do
    test "an UnknownAtom interval, an unknown zone or unknown components give {:error, :invalid}" do
      now = ~U[2026-03-10 12:00:00Z]

      for bad <- [
            s(interval: %UnknownAtom{value: "every_minute"}),
            s(interval: :hourly),
            s(time_zone: "Mars/Olympus_Mons"),
            s(components: [%UnknownAtom{value: "logs"}]),
            s(time_of_day: nil)
          ] do
        assert Window.latest(bad, now) == {:error, :invalid}
        assert Window.next(bad, now) == {:error, :invalid}
        assert Window.due(bad, now) == {:error, :invalid}
        refute Window.missed?(bad, ~U[2026-03-10 03:00:00Z])
      end
    end
  end

  test "stale_after_hours: daily 36, 2h 8, weekly 252, monthly 1116" do
    assert Window.stale_after_hours(:daily) == 36
    assert Window.stale_after_hours(:every_2h) == 8
    assert Window.stale_after_hours(:weekly) == 252
    assert Window.stale_after_hours(:monthly) == 1116
    assert Window.stale_after_hours(%UnknownAtom{value: "x"}) == nil
  end
end
