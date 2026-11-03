defmodule KilnCMS.Search.BudgetTest do
  @moduledoc """
  The scheduler behind `KilnCMS.Search.query_budget/0` (#2166), on sections
  that only sleep and send, so the deadline is the only thing under test.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search.Budget

  @opts [concurrency: 2, stall_timeout: 5_000]

  # A section that sends each leg, sleeping `ms` before each one.
  defp legs(steps) do
    fn %{emit: emit} ->
      Enum.reduce(steps, [], fn {leg, ms}, done ->
        Process.sleep(ms)
        emit && emit.(leg, leg)
        [leg | done]
      end)
    end
  end

  test "sections that finish in time are done, whatever the concurrency" do
    sections = [a: legs(one: 0), b: legs(two: 0), c: legs(three: 0)]

    for concurrency <- [1, 2, 8] do
      outcomes =
        Budget.run(sections, Budget.deadline(1_000),
          concurrency: concurrency,
          stall_timeout: 5_000
        )

      assert outcomes == %{a: {:done, [:one]}, b: {:done, [:two]}, c: {:done, [:three]}}
    end
  end

  test "a section the deadline stops keeps the legs it had sent" do
    sections = [slow: legs(keyword: 0, title: 0, semantic: 5_000)]

    {micros, outcomes} = :timer.tc(fn -> Budget.run(sections, Budget.deadline(100), @opts) end)

    assert outcomes == %{slow: {:cut, %{keyword: :keyword, title: :title}}}
    # Killed at the deadline, not left to finish its five seconds.
    assert micros < 1_000_000
  end

  test "sections not started by the deadline are cut with nothing" do
    # Two slots, both taken by sections that outlive the deadline.
    sections = [a: legs(x: 5_000), b: legs(x: 5_000), c: legs(x: 0)]

    outcomes = Budget.run(sections, Budget.deadline(50), @opts)

    assert outcomes == %{a: {:cut, %{}}, b: {:cut, %{}}, c: {:cut, %{}}}
  end

  test "a deadline already passed starts nothing, in either mode" do
    test_pid = self()
    sections = [a: fn _sweep -> send(test_pid, :ran) end]

    for concurrency <- [1, 2] do
      deadline = Budget.deadline(0)
      Process.sleep(1)

      assert Budget.run(sections, deadline, concurrency: concurrency, stall_timeout: 5_000) ==
               %{a: {:cut, %{}}}
    end

    refute_received :ran
  end

  test "fast sections finish while a slow one is cut" do
    sections = [fast: legs(one: 0), slow: legs(keyword: 0, semantic: 5_000), late: legs(two: 10)]

    outcomes = Budget.run(sections, Budget.deadline(200), @opts)

    assert outcomes.fast == {:done, [:one]}
    assert outcomes.late == {:done, [:two]}
    assert outcomes.slow == {:cut, %{keyword: :keyword}}
  end

  test "in the caller's process the deadline is checked between sections" do
    sections = [a: legs(x: 80), b: legs(y: 0)]

    outcomes = Budget.run(sections, Budget.deadline(40), concurrency: 1, stall_timeout: 5_000)

    # `a` was already running and is not interrupted; `b` does not start.
    assert outcomes == %{a: {:done, [:x]}, b: {:cut, %{}}}
  end

  test "a section that raises fails the call with its own error" do
    sections = [ok: legs(x: 0), bad: fn _sweep -> raise ArgumentError, "boom" end]

    assert_raise ArgumentError, "boom", fn ->
      Budget.run(sections, Budget.deadline(1_000), @opts)
    end
  end

  test "with no deadline, a section that makes no progress fails the call by name" do
    sections = [wedged: legs(x: 5_000)]

    assert_raise RuntimeError, ~r/\[:wedged\] made no progress in 50 ms/, fn ->
      Budget.run(sections, :infinity, concurrency: 2, stall_timeout: 50)
    end
  end

  test "no task outlives the call" do
    test_pid = self()

    wedged = fn _sweep ->
      send(test_pid, {:task, self()})
      Process.sleep(5_000)
    end

    Budget.run([a: wedged, b: wedged], Budget.deadline(30), @opts)

    assert_received {:task, a}
    assert_received {:task, b}
    refute Process.alive?(a)
    refute Process.alive?(b)
    refute_received _anything
  end

  describe "within_slots/4" do
    test "an abandoned call keeps its slot until it finishes, and its answer is dropped" do
      slots = make_ref()
      test_pid = self()

      slow = fn ->
        Process.sleep(300)
        send(test_pid, :ran)
        :late
      end

      assert Budget.within_slots(slots, 1, Budget.deadline(20), slow) == :timeout
      # Still in the "serving": the slot is held, so the next call is turned away
      # without running.
      assert Budget.in_flight(slots) == 1
      assert Budget.within_slots(slots, 1, Budget.deadline(500), fn -> :fast end) == :busy

      # It finished after all — and gave its slot back, without its answer
      # reaching a caller that had stopped waiting.
      assert_receive :ran, 1_000
      Process.sleep(20)
      assert Budget.in_flight(slots) == 0
      refute_received {_ref, _answer}

      assert Budget.within_slots(slots, 1, Budget.deadline(500), fn -> :fast end) == {:ok, :fast}
    end

    test "re-raises the work's own error and frees the slot" do
      slots = make_ref()

      assert_raise ArgumentError, "inner", fn ->
        Budget.within_slots(slots, 1, Budget.deadline(500), fn -> raise ArgumentError, "inner" end)
      end

      assert Budget.in_flight(slots) == 0
    end
  end
end
