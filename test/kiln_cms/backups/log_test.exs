defmodule KilnCMS.Backups.LogTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.{Log, LogEntry}

  defp entries(count),
    do:
      for(i <- 1..count, do: %{step: "s", message: "m#{i}", level: :info, at: DateTime.utc_now()})

  test "a short log is kept as is, as structs" do
    assert [%LogEntry{message: "m1"}, %LogEntry{message: "m2"}] = Log.cap(entries(2))
  end

  test "exactly the cap is untouched" do
    capped = Log.cap(entries(200))
    assert length(capped) == 200
    refute Enum.any?(capped, &(&1.step == "truncated"))
  end

  test "an overlong log keeps the first 50, the last 149 and one truncated marker" do
    capped = Log.cap(entries(1_000))

    assert length(capped) == 200
    assert Enum.at(capped, 0).message == "m1"
    assert Enum.at(capped, 49).message == "m50"
    assert %LogEntry{step: "truncated", level: :warn, message: marker} = Enum.at(capped, 50)
    assert marker =~ "801 log entries"
    assert Enum.at(capped, 51).message == "m852"
    assert List.last(capped).message == "m1000"
    assert Enum.count(capped, &(&1.step == "truncated")) == 1
  end

  test "capping is idempotent" do
    once = Log.cap(entries(500))
    assert Log.cap(once) == once
  end

  test "marker_count/1 reads the count from the marker cap/1 itself writes" do
    marker = 1_000 |> entries() |> Log.cap() |> Enum.find(&Log.marker?/1)

    assert Log.marker_count(marker) == 801
  end

  test "marker_count/1 is nil for any other line" do
    marker = 300 |> entries() |> Log.cap() |> Enum.find(&Log.marker?/1)

    assert Log.marker_count(%{marker | level: :info}) == nil
    assert Log.marker_count(%{marker | step: "dump"}) == nil
    assert Log.marker_count(%{marker | message: marker.message <> "!"}) == nil

    assert Log.marker_count(%{marker | message: "some log entries were dropped to bound the log"}) ==
             nil

    assert Log.marker_count(%LogEntry{step: "dump", level: :info, message: "m1"}) == nil
    assert Log.marker_count(:other) == nil
  end

  test "a log capped again counts the entries its old marker had dropped" do
    once = Log.cap(entries(300))
    assert once |> Enum.find(&Log.marker?/1) |> Log.marker_count() == 101

    appended = for i <- 301..400, do: %{step: "s", message: "m#{i}", level: :info}
    twice = Log.cap(once ++ appended)

    assert length(twice) == 200
    assert [marker] = Enum.filter(twice, &Log.marker?/1)
    assert Enum.at(twice, 50) == marker

    # 400 entries were written and 199 of them are kept.
    assert Log.marker_count(marker) == 400 - 199
    assert Enum.at(twice, 49).message == "m50"
    assert Enum.at(twice, 51).message == "m252"
    assert List.last(twice).message == "m400"
  end

  test "messages are cut to 500 characters and redacted" do
    long = String.duplicate("x", 900)

    [a, b] =
      Log.cap([
        %{step: "dump", message: long},
        %{step: "dump", message: "fail postgres://u:pw12345@h/db password=hunter2pw"}
      ])

    assert String.length(a.message) == 500
    refute b.message =~ "pw12345"
    refute b.message =~ "hunter2pw"
  end

  test "accepts string-keyed maps" do
    assert [%LogEntry{step: "x", message: "y", level: :info}] =
             Log.cap([%{"step" => "x", "message" => "y"}])
  end
end
