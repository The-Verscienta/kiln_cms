defmodule KilnCMS.Test.SearchHold do
  @moduledoc """
  A slow test embedder or reranker that lets go when its test ends (#2553).

  `KilnCMS.Search.Budget.within_slots/4` abandons a call that misses its
  deadline: it keeps running, and keeps its `:embed` / `:rerank` slot, until
  it returns. A test adapter that slept a fixed time outlived its test and
  held that slot in whatever ran next. `hold/1` instead waits for its delay
  or for `release_on_exit/0`'s release, whichever comes first, and
  `release_on_exit/0` waits for the slots to come back before the next test.

      setup do
        KilnCMS.Test.SearchHold.release_on_exit()
      end

      def embed(_text) do
        KilnCMS.Test.SearchHold.hold(:my_test_delay)
        {:ok, vector}
      end

  The app env it uses is global, so only `async: false` tests may use it.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias KilnCMS.Search.Budget

  @release :search_hold_release

  @doc "Wait for the `:kiln_cms` app env `delay_key`'s milliseconds, or for the release."
  @spec hold(atom()) :: :ok
  def hold(delay_key) do
    wait_until(System.monotonic_time(:millisecond) + Application.get_env(:kiln_cms, delay_key, 0))
  end

  defp wait_until(until) do
    cond do
      Application.get_env(:kiln_cms, @release, false) ->
        :ok

      System.monotonic_time(:millisecond) >= until ->
        :ok

      true ->
        Process.sleep(10)
        wait_until(until)
    end
  end

  @doc """
  On exit, release every held call and wait (up to five seconds) for the
  `:embed` and `:rerank` slots to drop back to where they were when this was
  called. Anything else in flight at the start (another test's call) may
  finish meanwhile, so "back" means at or below. Raises if they never do.
  """
  @spec release_on_exit() :: :ok
  def release_on_exit do
    baseline = in_flight()

    on_exit(fn ->
      Application.put_env(:kiln_cms, @release, true)

      try do
        settle(baseline, 5_000)
      after
        Application.delete_env(:kiln_cms, @release)
      end
    end)
  end

  defp in_flight, do: {Budget.in_flight(:embed), Budget.in_flight(:rerank)}

  defp settle({embed, rerank} = baseline, ms) do
    {now_embed, now_rerank} = in_flight()

    cond do
      now_embed <= embed and now_rerank <= rerank ->
        :ok

      ms <= 0 ->
        raise "held search calls still running after the test: #{inspect(in_flight())}"

      true ->
        Process.sleep(10)
        settle(baseline, ms - 10)
    end
  end
end
