defmodule KilnCMS.Backups.RetryTest do
  @moduledoc """
  `KilnCMS.Backups.Retry` (#2221): full-jitter exponential backoff, bounded
  in attempts and by the deadline, with the sleep injected so nothing here
  waits.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Retry

  defp classify(:busy), do: :transient
  defp classify(:refused), do: :permanent
  defp classify(:gone), do: :final

  # A fun answering `answers` in turn, and a sleep that records each delay.
  defp scripted(answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)
    test = self()

    fun = fn ->
      Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
    end

    sleep = fn ms -> send(test, {:slept, ms}) end
    {fun, sleep}
  end

  defp slept do
    receive do
      {:slept, ms} -> [ms | slept()]
    after
      0 -> []
    end
  end

  @opts [base_ms: 1_000, cap_ms: 30_000, attempts: 6, margin_ms: 30_000]

  test "retries transient errors until one succeeds" do
    {fun, sleep} = scripted([{:error, :busy}, {:error, :busy}, {:ok, :done}])

    assert Retry.run(fun, &classify/1, Keyword.put(@opts, :sleep, sleep)) == {:ok, :done}
    assert [first, second] = slept()
    assert first in 0..1_000
    assert second in 0..2_000
  end

  test "gives up after the attempts, answering the last error" do
    {fun, sleep} = scripted(List.duplicate({:error, :busy}, 10))

    assert Retry.run(fun, &classify/1, Keyword.put(@opts, :sleep, sleep)) == {:error, :busy}
    assert length(slept()) == 5
  end

  test "never retries a permanent or final error" do
    for reason <- [:refused, :gone] do
      {fun, sleep} = scripted([{:error, reason}, :ok])
      assert Retry.run(fun, &classify/1, Keyword.put(@opts, :sleep, sleep)) == {:error, reason}
      assert slept() == []
    end
  end

  test "the backoff doubles from the base up to the cap" do
    assert Enum.map(1..7, &Retry.ceiling(&1, @opts)) ==
             [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
  end

  test "a sleep that would end inside the margin before the deadline is not taken" do
    {fun, sleep} = scripted([{:error, :busy}, :ok])
    deadline = System.monotonic_time(:millisecond) + 29_000

    opts = @opts |> Keyword.put(:sleep, sleep) |> Keyword.put(:deadline, deadline)
    assert Retry.run(fun, &classify/1, Keyword.put(opts, :base_ms, 10_000)) == {:error, :deadline}
    assert slept() == []
  end

  test "with time to spare, the deadline changes nothing" do
    {fun, sleep} = scripted([{:error, :busy}, :ok])
    deadline = System.monotonic_time(:millisecond) + 3_600_000

    opts = @opts |> Keyword.put(:sleep, sleep) |> Keyword.put(:deadline, deadline)
    assert Retry.run(fun, &classify/1, opts) == :ok
    assert [_one] = slept()
  end
end
