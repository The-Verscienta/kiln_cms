defmodule KilnCMS.Backups.Retry do
  @moduledoc """
  Bounded retries for a backup destination's requests (#2221): full-jitter
  exponential backoff that never sleeps past the call's deadline.

  `run/3` calls `fun` until it succeeds, the error is not worth retrying, or
  the attempts run out. `classify` says what an error is:

    * `:transient` — retried, after a random sleep of up to
      `min(cap, base * 2^(attempt - 1))` (full jitter, so many nodes retrying
      one store don't retry in step);
    * `:permanent` or `:final` — answered at once. `:permanent` is a failure
      no retry fixes; `:final` one this request can't fix but the caller may
      (a missing upload, a missing object).

  With `:deadline` (a `System.monotonic_time(:millisecond)` instant), a sleep
  that would end later than `deadline - margin` is not taken: the answer is
  `{:error, :deadline}`, so the adapter stops while there is still time to
  report it, its progress saved.

  Options: `:attempts` (6), `:base_ms` (1 s), `:cap_ms` (30 s), `:margin_ms`
  (30 s), `:deadline` (none), `:sleep` (`Process.sleep/1`, injectable for
  tests). Defaults can be overridden in this module's application config.
  """

  @defaults [attempts: 6, base_ms: 1_000, cap_ms: 30_000, margin_ms: 30_000]

  @typedoc "What an error means to `run/3`."
  @type class :: :transient | :permanent | :final

  @doc """
  Runs `fun` (answering `:ok`, `{:ok, value}` or `{:error, reason}`) until it
  succeeds or `classify.(reason)` stops it. See the moduledoc.
  """
  @spec run((-> :ok | {:ok, term()} | {:error, term()}), (term() -> class()), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def run(fun, classify, opts \\ []) when is_function(fun, 0) and is_function(classify, 1) do
    loop(fun, classify, settings(opts), 1)
  end

  @doc """
  How close to a deadline no retry starts, in milliseconds: an adapter that
  watches its deadline stops this far before it too.
  """
  @spec margin_ms(keyword()) :: non_neg_integer()
  def margin_ms(opts \\ []), do: settings(opts).margin_ms

  @doc """
  The sleep before retry number `attempt` (1-based), before jitter:
  `min(cap, base * 2^(attempt - 1))`.
  """
  @spec ceiling(pos_integer(), keyword()) :: non_neg_integer()
  def ceiling(attempt, opts \\ []) do
    opts |> settings() |> ceiling_of(attempt)
  end

  defp ceiling_of(s, attempt), do: min(s.cap_ms, s.base_ms * Integer.pow(2, attempt - 1))

  defp loop(fun, classify, s, attempt) do
    case fun.() do
      {:error, reason} = error ->
        retry(fun, classify, s, attempt, error, classify.(reason))

      ok ->
        ok
    end
  end

  defp retry(fun, classify, s, attempt, _error, :transient) when attempt < s.attempts do
    ceiling = ceiling_of(s, attempt)
    delay = if ceiling > 0, do: :rand.uniform(ceiling + 1) - 1, else: 0

    if fits?(delay, s) do
      s.sleep.(delay)
      loop(fun, classify, s, attempt + 1)
    else
      {:error, :deadline}
    end
  end

  defp retry(_fun, _classify, _s, _attempt, error, _class), do: error

  defp fits?(_delay, %{deadline: nil}), do: true

  defp fits?(delay, %{deadline: deadline, margin_ms: margin}),
    do: System.monotonic_time(:millisecond) + delay <= deadline - margin

  defp settings(opts) do
    config = Application.get_env(:kiln_cms, __MODULE__, [])
    merged = @defaults |> Keyword.merge(config) |> Keyword.merge(opts)

    %{
      attempts: Keyword.fetch!(merged, :attempts),
      base_ms: Keyword.fetch!(merged, :base_ms),
      cap_ms: Keyword.fetch!(merged, :cap_ms),
      margin_ms: Keyword.fetch!(merged, :margin_ms),
      deadline: Keyword.get(merged, :deadline),
      sleep: Keyword.get(merged, :sleep, &Process.sleep/1)
    }
  end
end
