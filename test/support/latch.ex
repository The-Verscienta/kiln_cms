defmodule KilnCMS.Test.Latch do
  @moduledoc """
  A test-controlled hold that keeps a code path in flight until the test
  releases it (#1351).

  The instrumented code calls `enter/1` from its own process: the run is
  registered, announced to the listener as `{:latch_started, name, n}`, and
  held until the test calls `release_all/1`. That makes an "in flight" window
  the test's to open and close — not a sleep raced against LiveView
  round-trips or a scheduler.

  Three rules keep a broken latch loud rather than silently green — the
  post-merge review of the first cut found the failure mode where a
  miswired release degrades into a slower sleep and every test still passes:

    * **The caller's pid is bound OUTSIDE the Agent closure.** `self()` inside
      an `Agent.get_and_update/2` fun runs in the Agent's process and captures
      the Agent's own pid; the first cut did exactly that, so `release_all/0`
      released nobody. `latch_test.exs` pins the corrected behavior.
    * **`release_all/1` returns the pids it woke.** Assert on it —
      `assert [_] = release_all(name)` — so "the latch did the releasing" is a
      positive claim, not an assumption. An empty return means the run was
      never held: released too early, or never started.
    * **The bounded fallback announces itself.** A run nobody releases
      completes after #{1_500}ms so a broken test fails on its own assertions
      instead of hanging — but it also sends `{:latch_timeout, name, pid}` to
      the listener, so a trailing `refute_received {:latch_timeout, _, _}`
      (or the `release_all` return) turns silent degrade into a failure. The
      fallback sits deliberately under the suite's smallest 2s `render_async`
      budget, so a run reached through a *broken guard* still finishes inside
      the caller's own window and fails on the assertion that names the bug.

  `enter/1` runs a bare selective `receive`, so it is only valid in a
  disposable process that owns its mailbox — a `start_async` task, a
  `Task.async`, a Cachex courier worker — never in a GenServer loop.
  """

  use Agent

  @fallback_ms 1_500

  @doc """
  Start a named latch reporting to `listener` (explicit, following
  `StubBillingProvider.spy_on/2`'s shape — never captured implicitly).
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    listener = Keyword.fetch!(opts, :listener)
    Agent.start_link(fn -> new_state(listener) end, name: name)
  end

  defp new_state(listener), do: %{entered: 0, held: [], released?: false, listener: listener}

  @doc "How many runs have entered since the last reset."
  def entered(name), do: Agent.get(name, & &1.entered)

  @doc """
  Release any still-held runs, then re-arm with a zero count and `listener`.
  Releasing first means a reset can never orphan a held run into its fallback.
  """
  def reset(name, listener) do
    release_all(name)
    Agent.update(name, fn _ -> new_state(listener) end)
  end

  @doc """
  Let every held run complete, and return the pids that were actually woken —
  assert on the return. Sticky until the next `reset/2`: a run that only
  starts after this call (one a broken guard let through) completes on
  arrival rather than waiting out the fallback.
  """
  def release_all(name) do
    held = Agent.get_and_update(name, fn s -> {s.held, %{s | held: [], released?: true}} end)
    Enum.each(held, &send(&1, {:latch_release, name}))
    held
  end

  @doc """
  Register, announce, and hold the calling process until released (or until
  the fallback). Returns this run's ordinal, which is the run's own identity —
  use it, not a re-read of the shared count.
  """
  def enter(name) do
    # Bound HERE, in the calling process — inside the Agent fun below,
    # `self()` would be the Agent (the first cut's confirmed bug).
    caller = self()

    {n, released?, listener} =
      Agent.get_and_update(name, fn s ->
        n = s.entered + 1
        held = if s.released?, do: s.held, else: [caller | s.held]
        {{n, s.released?, s.listener}, %{s | entered: n, held: held}}
      end)

    send(listener, {:latch_started, name, n})

    unless released? do
      receive do
        {:latch_release, ^name} -> :ok
      after
        @fallback_ms -> send(listener, {:latch_timeout, name, caller})
      end
    end

    n
  end
end
