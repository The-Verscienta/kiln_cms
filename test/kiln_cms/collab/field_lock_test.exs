defmodule KilnCMS.Collab.FieldLockTest do
  @moduledoc false
  # Each test owns a topic of its own, so the per-record processes never
  # meet; the timings are per process, so a short grace here is nobody
  # else's short grace.
  use ExUnit.Case, async: true

  alias KilnCMS.Collab.FieldLock

  @alice %{id: "alice", name: "Alice"}
  @bob %{id: "bob", name: "Bob"}

  setup do
    topic = "editing:page:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
    {:ok, topic: topic}
  end

  # A lock process with short clocks, registered where the API looks for it.
  defp start(topic, opts) do
    start_supervised!({FieldLock, Keyword.merge([topic: topic], opts)})
  end

  defp unregistered?(topic, tries \\ 50) do
    case Registry.lookup(FieldLock.registry(), topic) do
      [] -> true
      _ when tries > 0 -> Process.sleep(10) && unregistered?(topic, tries - 1)
      _ -> false
    end
  end

  # A stand-in session: a process that lives until told otherwise.
  defp session do
    spawn_link(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "acquire/4" do
    test "a free field is granted; the next asker is told who holds it", %{topic: topic} do
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())

      assert_receive {:field_locks, ^topic, %{"title" => %{user_id: "alice", name: "Alice"}}}

      other = session()

      assert {:held, %{user_id: "alice", pid: me}} =
               FieldLock.acquire(topic, "title", @bob, other)

      assert me == self()

      # And the same holds for the holder's own second tab.
      assert {:held, %{user_id: "alice"}} = FieldLock.acquire(topic, "title", @alice, other)
    end

    test "re-focusing a field you hold is a no-op that counts as activity", %{topic: topic} do
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      %{last_keystroke_at: before} = FieldLock.holder(topic, "title")
      Process.sleep(5)

      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      %{last_keystroke_at: after_refocus} = FieldLock.holder(topic, "title")
      assert DateTime.compare(after_refocus, before) == :gt
    end

    test "fields lock independently", %{topic: topic} do
      other = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert :ok = FieldLock.acquire(topic, "slug", @bob, other)

      assert %{"title" => %{user_id: "alice"}, "slug" => %{user_id: "bob"}} =
               FieldLock.locks(topic)
    end
  end

  describe "release" do
    test "release/3 frees the field for the holder only", %{topic: topic} do
      other = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())

      # Somebody else's blur cannot let go of a field they don't hold.
      assert :ok = FieldLock.release(topic, "title", other)
      assert %{"title" => _} = FieldLock.locks(topic)

      assert :ok = FieldLock.release(topic, "title", self())
      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0
      assert FieldLock.locks(topic) == %{}
    end

    test "release_all/2 frees every field a session holds", %{topic: topic} do
      other = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert :ok = FieldLock.acquire(topic, "excerpt", @alice, self())
      assert :ok = FieldLock.acquire(topic, "slug", @bob, other)

      assert :ok = FieldLock.release_all(topic, self())
      assert %{"slug" => %{user_id: "bob"}} = locks = FieldLock.locks(topic)
      assert map_size(locks) == 1
    end

    test "the process stops once every field is free and nobody waits", %{topic: topic} do
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      [{pid, _}] = Registry.lookup(FieldLock.registry(), topic)
      ref = Process.monitor(pid)

      assert :ok = FieldLock.release(topic, "title", self())
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      # The Registry drops the name a beat after the process exits.
      assert unregistered?(topic)

      # A record without a process is free without starting one.
      assert FieldLock.locks(topic) == %{}
      assert :ok = FieldLock.release(topic, "title", self())
      assert unregistered?(topic)
    end
  end

  describe "process death and the grace period" do
    test "a dead holder keeps the field through the grace, then loses it", %{topic: topic} do
      start(topic, grace_ms: 80)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      assert_receive {:field_locks, ^topic, %{"title" => _}}

      send(holder, :stop)

      # Still held while the grace runs: a reload must not cost the lock.
      Process.sleep(20)
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)

      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0, 500
    end

    test "the same user coming back inside the grace gets the field straight back",
         %{topic: topic} do
      start(topic, grace_ms: 5_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      send(holder, :stop)
      # Let the monitor notice before the reload arrives.
      Process.sleep(20)

      # Somebody else is still refused: the grace is the holder's.
      assert {:held, %{user_id: "alice"}} = FieldLock.acquire(topic, "title", @bob, session())

      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert %{"title" => %{pid: me}} = FieldLock.locks(topic)
      assert me == self()
    end
  end

  describe "the idle timeout" do
    test "a silent holder loses the field; a keystroke restarts the clock", %{topic: topic} do
      start(topic, idle_ms: 120)
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert_receive {:field_locks, ^topic, %{"title" => _}}

      Process.sleep(80)
      FieldLock.ping(topic, self())
      Process.sleep(80)
      # 160 ms in, but only 80 since the last keystroke.
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)

      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0, 500
    end

    test "ping/2 moves last_keystroke_at for every field the session holds", %{topic: topic} do
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert :ok = FieldLock.acquire(topic, "slug", @alice, self())
      before = FieldLock.locks(topic)
      Process.sleep(5)

      FieldLock.ping(topic, self())
      after_ping = FieldLock.locks(topic)

      for field <- ["title", "slug"] do
        assert DateTime.compare(
                 after_ping[field].last_keystroke_at,
                 before[field].last_keystroke_at
               ) ==
                 :gt
      end

      # Nobody else's clock moved.
      assert after_ping["title"].acquired_at == before["title"].acquired_at
    end
  end

  describe "takeover/4" do
    test "a free field is granted at once", %{topic: topic} do
      assert :ok = FieldLock.takeover(topic, "title", @bob, self())
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
    end

    test "asks the holder to flush, then transfers on flushed/2", %{topic: topic} do
      holder = self()
      taker = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, taker)
      assert_receive {:lock_flush, ^topic, "title"}

      # Nothing moves until the holder answers.
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)

      FieldLock.flushed(topic, "title")

      assert_receive {:lock_taken, ^topic, "title", %{id: "bob", name: "Bob"}}
      assert_receive {:field_locks, ^topic, %{"title" => %{user_id: "bob", pid: ^taker}}}
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
    end

    test "tells the taker with {:lock_granted, _, _}", %{topic: topic} do
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, self())
      FieldLock.flushed(topic, "title")

      assert_receive {:lock_granted, ^topic, "title"}
    end

    test "a holder that does not answer is not waited for", %{topic: topic} do
      start(topic, flush_ms: 60)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, self())
      refute_receive {:lock_granted, _, _}, 30

      assert_receive {:lock_granted, ^topic, "title"}, 500
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
    end

    test "a holder whose tab is gone is displaced at once — nothing to flush", %{topic: topic} do
      start(topic, grace_ms: 5_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      send(holder, :stop)
      Process.sleep(20)

      assert :ok = FieldLock.takeover(topic, "title", @bob, self())
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
    end

    test "a second asker while the flush is pending is the one who gets it", %{topic: topic} do
      holder = session()
      first = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, first)
      assert :pending = FieldLock.takeover(topic, "title", %{id: "carol", name: "Carol"}, self())

      FieldLock.flushed(topic, "title")
      assert_receive {:lock_granted, ^topic, "title"}
      assert %{"title" => %{user_id: "carol"}} = FieldLock.locks(topic)
    end

    test "taking over a field you already hold is a no-op", %{topic: topic} do
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert :ok = FieldLock.takeover(topic, "title", @alice, self())
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)
    end

    test "a stray flushed/2 with nobody waiting changes nothing", %{topic: topic} do
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      FieldLock.flushed(topic, "title")
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)
    end
  end

  describe "typing?/2" do
    test "is the 30-second window on the last keystroke" do
      now = ~U[2026-09-11 12:00:00Z]
      holder = %{last_keystroke_at: ~U[2026-09-11 11:59:40Z], acquired_at: now}
      assert FieldLock.typing?(holder, now)

      holder = %{holder | last_keystroke_at: ~U[2026-09-11 11:59:20Z]}
      refute FieldLock.typing?(holder, now)
    end
  end
end
