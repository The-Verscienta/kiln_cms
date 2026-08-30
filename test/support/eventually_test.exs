defmodule KilnCMS.Test.EventuallyTest do
  @moduledoc """
  The deadline poller the suite's eventually-consistent assertions stand on
  (#1349). A poller that cannot fail looks identical to one that can — the
  defect this module replaced — so the exhaustion paths are pinned here, not
  assumed.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Test.Eventually

  test "returns the check's truthy value, not just :ok" do
    assert Eventually.eventually(fn -> "the value" end) == "the value"
  end

  test "polls a condition that starts false and comes true" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert Eventually.eventually(fn ->
             Agent.get_and_update(counter, &{&1, &1 + 1}) >= 2
           end)
  end

  test "flunks at the deadline with the default message" do
    assert_raise ExUnit.AssertionError, ~r/the polled condition never held within 60ms/, fn ->
      Eventually.eventually(fn -> false end, timeout_ms: 60)
    end
  end

  test "nil is falsy, and a string message names the condition" do
    assert_raise ExUnit.AssertionError, ~r/the lock never freed \(within 60ms\)/, fn ->
      Eventually.eventually(fn -> nil end, timeout_ms: 60, message: "the lock never freed")
    end
  end

  test "a fun message runs at flunk time and can capture last state" do
    {:ok, state} = Agent.start_link(fn -> "settled late" end)

    assert_raise ExUnit.AssertionError, ~r/last state: settled late/, fn ->
      Eventually.eventually(fn -> false end,
        timeout_ms: 60,
        message: fn -> "never held; last state: #{Agent.get(state, & &1)}" end
      )
    end
  end

  test "a fun message is not evaluated on the passing path" do
    assert Eventually.eventually(fn -> :ok end,
             message: fn -> raise "message fun ran on a passing check" end
           ) == :ok
  end
end
