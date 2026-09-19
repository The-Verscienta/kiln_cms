defmodule KilnCMS.Media.TransformGateTest do
  @moduledoc """
  The render gate: a fixed number of slots, a bounded wait, a bounded queue —
  and slots that come back when their holder dies, because a slot leaked per
  killed request would eventually wedge the transform endpoint shut.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Media.TransformGate

  setup do
    gate = start_supervised!({TransformGate, name: nil, slots: 1, max_queue: 1})
    %{gate: gate}
  end

  # Holds the gate's only slot from another process until told to let go.
  defp hold(gate) do
    test = self()

    pid =
      spawn(fn ->
        TransformGate.run(
          fn ->
            send(test, {:holding, self()})

            receive do
              :release -> :ok
            end
          end,
          server: gate
        )
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  test "runs the function and returns its result", %{gate: gate} do
    assert TransformGate.run(fn -> :rendered end, server: gate) == :rendered
    assert %{busy: 0, waiting: 0} = TransformGate.stats(gate)
  end

  test "releases the slot when the function raises", %{gate: gate} do
    assert_raise RuntimeError, fn -> TransformGate.run(fn -> raise "boom" end, server: gate) end
    assert TransformGate.run(fn -> :next end, server: gate) == :next
  end

  test "a caller waits for a busy slot and runs when it frees", %{gate: gate} do
    holder = hold(gate)
    waiter = Task.async(fn -> TransformGate.run(fn -> :after_wait end, server: gate) end)

    wait_until(fn -> TransformGate.stats(gate).waiting == 1 end)
    send(holder, :release)

    assert Task.await(waiter) == :after_wait
  end

  test "a caller that waits past its timeout is told the gate is busy", %{gate: gate} do
    holder = hold(gate)
    assert TransformGate.run(fn -> :never end, server: gate, timeout: 20) == {:error, :busy}
    assert %{busy: 1, waiting: 0} = TransformGate.stats(gate)
    send(holder, :release)
  end

  test "a full queue refuses at once rather than queueing without bound", %{gate: gate} do
    holder = hold(gate)
    queued = Task.async(fn -> TransformGate.run(fn -> :queued end, server: gate) end)
    wait_until(fn -> TransformGate.stats(gate).waiting == 1 end)

    assert TransformGate.run(fn -> :never end, server: gate, timeout: 5_000) == {:error, :busy}

    send(holder, :release)
    assert Task.await(queued) == :queued
  end

  test "a holder that dies gives its slot back", %{gate: gate} do
    holder = hold(gate)
    Process.exit(holder, :kill)

    assert TransformGate.run(fn -> :recovered end, server: gate, timeout: 1_000) == :recovered
  end

  test "a waiter that dies leaves the queue", %{gate: gate} do
    holder = hold(gate)
    waiter = spawn(fn -> TransformGate.run(fn -> :never end, server: gate) end)
    wait_until(fn -> TransformGate.stats(gate).waiting == 1 end)

    Process.exit(waiter, :kill)
    wait_until(fn -> TransformGate.stats(gate).waiting == 0 end)

    send(holder, :release)
    assert TransformGate.run(fn -> :fine end, server: gate) == :fine
  end

  test "a slot granted just as the waiter timed out is used, not leaked", %{gate: gate} do
    holder = hold(gate)

    # Release the holder so the grant races the waiter's timeout; whichever
    # wins, the gate must end with no slot held.
    waiter =
      Task.async(fn -> TransformGate.run(fn -> :raced end, server: gate, timeout: 1) end)

    send(holder, :release)
    assert Task.await(waiter) in [:raced, {:error, :busy}]
    wait_until(fn -> TransformGate.stats(gate) == %{busy: 0, waiting: 0} end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end
end
