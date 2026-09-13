defmodule KilnCMSWeb.RoleGrantFormTest do
  @moduledoc "The shared temporary-grant form helpers, and the countdown they render."
  use ExUnit.Case, async: true

  alias KilnCMSWeb.CoreComponents
  alias KilnCMSWeb.RoleGrantForm

  defp hours_from_now(%DateTime{} = at),
    do: DateTime.diff(at, DateTime.utc_now(), :second) / 3600

  describe "expiry/1" do
    test "an explicit datetime wins, with or without seconds" do
      for until <- ["2099-01-02T03:04", "2099-01-02T03:04:05"] do
        assert %DateTime{year: 2099, month: 1, day: 2, hour: 3, minute: 4} =
                 RoleGrantForm.expiry(%{"until" => until, "hours" => "24"})
      end
    end

    test "a blank or unparseable datetime falls back to the preset, never nil" do
      for until <- ["", "23/09/2026 14:30", "nope"] do
        at = RoleGrantForm.expiry(%{"until" => until, "hours" => "72"})
        assert_in_delta hours_from_now(at), 72, 0.1
      end
    end

    # A mangled preset must hand out the SHORTEST grant, not the longest.
    test "an unknown or malformed preset falls back to the shortest duration" do
      for hours <- ["9999", "abc", ["24"], "-5"] do
        at = RoleGrantForm.expiry(%{"hours" => hours})
        assert_in_delta hours_from_now(at), 6, 0.1
      end
    end

    test "a bracketed until reads as absent" do
      at = RoleGrantForm.expiry(%{"until" => ["2099-01-02T03:04"], "hours" => "24"})
      assert_in_delta hours_from_now(at), 24, 0.1
    end
  end

  describe "time_left/1" do
    # Rounded up: a fresh 72h grant is "3 days", not the "2 days" the old double
    # truncation printed beside a timestamp three days out.
    test "rounds up so a fresh grant reads as its full duration" do
      for {hours, label} <- [
            {72, "3 days left"},
            {168, "7 days left"},
            {720, "30 days left"},
            {24, "24 hours left"}
          ] do
        at = DateTime.add(DateTime.utc_now(), hours * 3600 - 2, :second)
        assert CoreComponents.time_left(at) == label
      end
    end

    test "pluralizes the singular" do
      at = DateTime.add(DateTime.utc_now(), 3600 + 30, :second)
      assert CoreComponents.time_left(at) == "2 hours left"

      at = DateTime.add(DateTime.utc_now(), 3600 - 30, :second)
      assert CoreComponents.time_left(at) == "under an hour left"
    end

    test "a passed deadline reads as expired" do
      assert CoreComponents.time_left(DateTime.add(DateTime.utc_now(), -60, :second)) == "expired"
    end
  end
end
