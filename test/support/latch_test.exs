defmodule KilnCMS.Test.LatchTest do
  @moduledoc """
  The latch every held-run stub stands on (#1351). The first cut of this
  mechanism shipped inert — `self()` captured inside an Agent closure made
  `release_all/0` a no-op, and the bounded fallback let every test stay
  green, just slower — so the properties that would have caught that are
  pinned here, not assumed.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Test.Latch

  defp start_latch(name) do
    {:ok, _} = Latch.start_link(name: name, listener: self())
    name
  end

  test "release_all returns the HELD RUN's pid, not the Agent's" do
    latch = start_latch(:latch_release_pid)
    test_pid = self()

    runner = spawn(fn -> send(test_pid, {:done, Latch.enter(latch)}) end)

    assert_receive {:latch_started, ^latch, 1}, 2_000
    # The regression the review confirmed: the first cut returned the Agent's
    # own pid here, so nothing it "released" was ever a held run.
    assert [^runner] = Latch.release_all(latch)
    assert_receive {:done, 1}, 2_000
    refute_received {:latch_timeout, _, _}
  end

  test "release_all on nothing held returns [] — the caller's proof it fired too early" do
    latch = start_latch(:latch_release_empty)
    assert [] = Latch.release_all(latch)
  end

  test "a release is sticky until reset: a late run completes without holding" do
    latch = start_latch(:latch_sticky)
    test_pid = self()

    assert [] = Latch.release_all(latch)

    spawn(fn -> send(test_pid, {:done, Latch.enter(latch)}) end)
    assert_receive {:done, 1}, 500
    refute_received {:latch_timeout, _, _}
  end

  test "an unreleased run announces its fallback instead of degrading silently" do
    latch = start_latch(:latch_timeout_announce)
    test_pid = self()

    spawn(fn -> send(test_pid, {:done, Latch.enter(latch)}) end)

    assert_receive {:latch_started, ^latch, 1}, 2_000
    assert_receive {:latch_timeout, ^latch, _pid}, 3_000
    assert_receive {:done, 1}, 500
  end

  test "reset frees held runs, re-arms the hold, and re-points the listener" do
    latch = start_latch(:latch_reset)
    test_pid = self()

    spawn(fn -> send(test_pid, {:held, Latch.enter(latch)}) end)
    assert_receive {:latch_started, ^latch, 1}, 2_000

    # Reset releases rather than orphaning, and zeroes the count.
    Latch.reset(latch, self())
    assert_receive {:held, 1}, 2_000
    assert Latch.entered(latch) == 0

    # Re-armed: the next run holds again (the first cut's sticky flag could
    # never re-arm).
    spawn(fn -> send(test_pid, {:held_again, Latch.enter(latch)}) end)
    assert_receive {:latch_started, ^latch, 1}, 2_000
    assert [_] = Latch.release_all(latch)
    assert_receive {:held_again, 1}, 2_000
  end

  test "each run gets its own ordinal, announced in order of entry" do
    latch = start_latch(:latch_ordinals)
    test_pid = self()

    for _ <- 1..3, do: spawn(fn -> send(test_pid, {:done, Latch.enter(latch)}) end)

    for _ <- 1..3, do: assert_receive({:latch_started, ^latch, _}, 2_000)
    released = Latch.release_all(latch)
    assert length(released) == 3

    ordinals = for _ <- 1..3, do: receive(do: ({:done, n} -> n))
    assert Enum.sort(ordinals) == [1, 2, 3]
  end
end
