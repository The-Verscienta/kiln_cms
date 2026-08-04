defmodule Kiln.Forms.SpamCheck.Checks.FillTimeTest do
  use ExUnit.Case, async: true

  alias Kiln.Forms.SpamCheck.Checks.FillTime
  alias Kiln.Forms.SpamCheck.Context

  test "no fact computed (e.g. a headless caller) is not flagged" do
    assert FillTime.check(Context.new(%{})) == :ok
  end

  test "a plausible human fill time is not flagged" do
    ctx = Context.new(%{}, facts: %{fill_time_ms: 8_000})
    assert FillTime.check(ctx) == :ok
  end

  test "a submission filled faster than any human could is flagged" do
    ctx = Context.new(%{}, facts: %{fill_time_ms: 100})
    assert {:flag, :submitted_too_fast, weight} = FillTime.check(ctx)
    assert weight > 0
  end

  test "a negative or non-integer fact is not flagged rather than crashing" do
    assert FillTime.check(Context.new(%{}, facts: %{fill_time_ms: -5})) == :ok
    assert FillTime.check(Context.new(%{}, facts: %{fill_time_ms: "soon"})) == :ok
  end
end
