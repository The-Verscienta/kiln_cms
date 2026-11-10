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

  # The lock process of a topic and its private state. Timeouts are driven by
  # sending the timer's own message, read from here, rather than by racing a
  # real clock.
  defp lock_pid(topic) do
    [{pid, _}] = Registry.lookup(FieldLock.registry(), topic)
    pid
  end

  defp lock_state(topic), do: topic |> lock_pid() |> :sys.get_state()

  # Polls until the private holder of `field` satisfies `ready?`, and returns it.
  defp await_holder(topic, field, ready?, tries \\ 100) do
    holder = lock_state(topic).locks[field]

    cond do
      holder && ready?.(holder) -> holder
      tries > 0 -> Process.sleep(5) && await_holder(topic, field, ready?, tries - 1)
      true -> flunk("the holder of #{field} never got ready: #{inspect(holder)}")
    end
  end

  # Waits for a stand-in session to have exited.
  defp await_exit(pid, tries \\ 100) do
    cond do
      not Process.alive?(pid) -> :ok
      tries > 0 -> Process.sleep(5) && await_exit(pid, tries - 1)
      true -> flunk("#{inspect(pid)} never exited")
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
      start(topic, grace_ms: 60_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      assert_receive {:field_locks, ^topic, %{"title" => _}}

      send(holder, :stop)
      %{gen: gen} = await_holder(topic, "title", &(&1.grace_timer != nil))

      # Still held while the grace runs: a reload must not cost the lock.
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)

      send(lock_pid(topic), {:grace_over, "title", gen})
      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0
    end

    test "the grace runs on a real clock", %{topic: topic} do
      start(topic, grace_ms: 50)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      send(holder, :stop)

      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0, 2_000
    end

    test "the same user coming back inside the grace gets the field straight back",
         %{topic: topic} do
      start(topic, grace_ms: 5_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      send(holder, :stop)
      # The reload arrives after the old tab is gone.
      await_exit(holder)

      # Somebody else is still refused: the grace is the holder's.
      assert {:held, %{user_id: "alice"}} = FieldLock.acquire(topic, "title", @bob, session())

      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert %{"title" => %{pid: me}} = FieldLock.locks(topic)
      assert me == self()
    end
  end

  describe "the idle timeout" do
    test "a silent holder loses the field", %{topic: topic} do
      start(topic, idle_ms: 50)
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert_receive {:field_locks, ^topic, %{"title" => _}}

      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0, 2_000
    end

    test "a keystroke restarts the clock: the timeout it replaced does nothing",
         %{topic: topic} do
      start(topic, idle_ms: 60_000)
      assert :ok = FieldLock.acquire(topic, "title", @alice, self())
      assert_receive {:field_locks, ^topic, %{"title" => _}}
      %{idle_ref: first} = lock_state(topic).locks["title"]

      FieldLock.ping(topic, self())
      %{idle_ref: second} = lock_state(topic).locks["title"]
      assert second != first

      # The first timer fired just as the keystroke landed: its message is
      # already queued and cancelling it no longer helps.
      send(lock_pid(topic), {:idle_over, "title", first})
      assert %{"title" => %{user_id: "alice"}} = FieldLock.locks(topic)

      send(lock_pid(topic), {:idle_over, "title", second})
      assert_receive {:field_locks, ^topic, locks} when map_size(locks) == 0
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
      start(topic, flush_ms: 60_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, self())
      %{ref: ref} = lock_state(topic).pending["title"]
      refute_received {:lock_granted, _, _}

      send(lock_pid(topic), {:flush_timeout, "title", ref})
      assert_receive {:lock_granted, ^topic, "title"}
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
    end

    test "the flush wait runs on a real clock", %{topic: topic} do
      start(topic, flush_ms: 50)
      assert :ok = FieldLock.acquire(topic, "title", @alice, session())

      assert :pending = FieldLock.takeover(topic, "title", @bob, self())
      assert_receive {:lock_granted, ^topic, "title"}, 2_000
    end

    test "a stale flush timeout does not grant a later takeover early", %{topic: topic} do
      start(topic, flush_ms: 60_000)
      holder = session()
      bob = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, bob)
      %{ref: stale} = lock_state(topic).pending["title"]
      FieldLock.flushed(topic, "title")
      assert_receive {:field_locks, ^topic, %{"title" => %{user_id: "bob"}}}

      assert :pending = FieldLock.takeover(topic, "title", %{id: "carol", name: "Carol"}, self())
      %{ref: current} = lock_state(topic).pending["title"]
      assert current != stale

      # The first takeover's timer fired as its flush answered.
      send(lock_pid(topic), {:flush_timeout, "title", stale})
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
      refute_received {:lock_granted, _, _}

      send(lock_pid(topic), {:flush_timeout, "title", current})
      assert_receive {:lock_granted, ^topic, "title"}
      assert %{"title" => %{user_id: "carol"}} = FieldLock.locks(topic)
    end

    test "a holder released mid-flush still lets the timeout grant the field",
         %{topic: topic} do
      start(topic, flush_ms: 60_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)

      assert :pending = FieldLock.takeover(topic, "title", @bob, self())
      %{ref: ref} = lock_state(topic).pending["title"]
      assert :ok = FieldLock.release(topic, "title", holder)

      send(lock_pid(topic), {:flush_timeout, "title", ref})
      assert_receive {:lock_granted, ^topic, "title"}
      assert %{"title" => %{user_id: "bob"}} = FieldLock.locks(topic)
    end

    test "a holder whose tab is gone is displaced at once — nothing to flush", %{topic: topic} do
      start(topic, grace_ms: 5_000)
      holder = session()
      assert :ok = FieldLock.acquire(topic, "title", @alice, holder)
      send(holder, :stop)
      await_exit(holder)

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

    test "a second asker is granted by the first asker's flush timeout", %{topic: topic} do
      start(topic, flush_ms: 60_000)
      assert :ok = FieldLock.acquire(topic, "title", @alice, session())

      assert :pending = FieldLock.takeover(topic, "title", @bob, session())
      %{ref: ref} = lock_state(topic).pending["title"]
      assert :pending = FieldLock.takeover(topic, "title", %{id: "carol", name: "Carol"}, self())

      send(lock_pid(topic), {:flush_timeout, "title", ref})
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
