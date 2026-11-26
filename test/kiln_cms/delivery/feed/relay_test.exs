defmodule KilnCMS.Delivery.Feed.RelayTest do
  @moduledoc """
  #2083: the change feed's local fan-out runs in a per-site relay, not in the
  publisher, keeps one site's events in order, and falls back to an inline
  broadcast when no relay is running.
  """
  # Not async: one test suspends a relay of the application's
  # PartitionSupervisor, and every other site that hashes to that partition
  # would stall with it.
  use ExUnit.Case, async: false

  # The anonymous view's exposure read failing is logged; "publish/4 when the
  # anonymous view fails" asserts what it logs.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Delivery.Feed
  alias KilnCMS.Delivery.Feed.Event
  alias KilnCMS.Delivery.Feed.Relay
  alias KilnCMS.Repo

  # A site of its own per test: nothing else publishes to it.
  #
  # And a connection of its own (#2938), not shared: without one, the
  # publisher's anonymous-view read (#2275) went through whatever sandbox mode
  # the previous synchronous test left, and a shared owner stopping just then
  # made the read exit. The read now succeeds and finds no exposure, so the
  # event is hidden from SSE streams; the failing read is tested on its own
  # below, from a process that holds no connection.
  setup do
    owner = Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    site = Ecto.UUID.generate()
    :ok = Feed.subscribe(site)
    %{site: site}
  end

  defp publish!(site, id),
    do: :ok = Feed.publish("page.published", %{id: id, state: :published}, site)

  describe "publish/4" do
    test "returns before the relay has broadcast: the fan-out is off the publisher", %{site: site} do
      relay = Relay.whereis(site)
      assert is_pid(relay)

      :ok = :sys.suspend(relay)
      on_exit(fn -> resume(relay) end)

      id = Ecto.UUID.generate()
      # Would block here if the publisher still delivered to subscribers itself
      # or waited on the relay.
      publish!(site, id)
      refute_received {:kiln_feed, %Event{id: ^id}}

      :ok = :sys.resume(relay)
      :ok = Feed.sync(site)
      assert_received {:kiln_feed, %Event{id: ^id, kind: :published}}
    end

    test "delivers one site's events in the order they were published", %{site: site} do
      ids = for _ <- 1..50, do: Ecto.UUID.generate()
      Enum.each(ids, &publish!(site, &1))

      :ok = Feed.sync(site)
      assert drain() == ids
    end

    test "each site's events reach that site's subscribers only", %{site: site} do
      other = Ecto.UUID.generate()
      mine = Ecto.UUID.generate()
      theirs = Ecto.UUID.generate()

      publish!(site, mine)
      publish!(other, theirs)

      :ok = Feed.sync(site)
      :ok = Feed.sync(other)
      assert drain() == [mine]

      :ok = Feed.subscribe(other)
      publish!(other, theirs)
      :ok = Feed.sync(other)
      assert drain() == [theirs]
    end
  end

  # The anonymous view only gates SSE streams: when its read fails, the event
  # is hidden from them and the relay still delivers it. Published from a bare
  # process (not a Task, whose `$callers` would lend it the test's
  # connection), so the read has no connection of its own.
  describe "publish/4 when the anonymous view fails" do
    test "a read that raises hides the event from streams and still delivers it", %{site: site} do
      :ok = Sandbox.mode(Repo, :manual)
      id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          publish_from_bare_process!(site, id)
          :ok = Feed.sync(site)
        end)

      assert_received {:kiln_feed, %Event{id: ^id, anonymous: :hide, sse: nil}}
      assert log =~ "Feed exposure for #{id} not read"
    end

    # #2938: a shared owner going away while the read waits on its connection
    # makes the checkout exit, and the exit used to drop the event for every
    # in-BEAM subscriber.
    test "a read that exits hides the event from streams and still delivers it", %{site: site} do
      shared = Sandbox.start_owner!(Repo, shared: true)
      # Keep the shared connection busy so the read queues on it.
      Agent.cast(shared, fn state ->
        Repo.query!("SELECT pg_sleep(5)")
        state
      end)

      id = Ecto.UUID.generate()
      test = self()

      log =
        capture_log(fn ->
          publisher =
            spawn(fn ->
              publish!(site, id)
              send(test, :published)
            end)

          wait_until_checking_out(publisher)
          Process.exit(shared, :kill)

          assert_receive :published, 5_000
          :ok = Feed.sync(site)
        end)

      assert_received {:kiln_feed, %Event{id: ^id, anonymous: :hide, sse: nil}}
      assert log =~ "Feed event #{id} hidden from streams"
      refute log =~ "not published"
    end
  end

  describe "dispatch/4 without a relay" do
    test "broadcasts inline and does not exit the caller", %{site: site} do
      message = {:kiln_feed, %Event{kind: :published, type: "page", id: Ecto.UUID.generate()}}

      assert Relay.whereis(NoSuchRelays, site) == nil
      assert Relay.dispatch(NoSuchRelays, site, Feed.topic(site), message) == :ok
      # Inline: already in the mailbox, no sync needed.
      assert_received ^message

      assert Relay.sync(NoSuchRelays, site) == :ok
    end
  end

  describe "a relay" do
    test "logs a broadcast it cannot make and keeps serving", %{site: site} do
      relay = start_supervised!(Relay)
      message = {:kiln_feed, %Event{kind: :updated, type: "page", id: Ecto.UUID.generate()}}

      log =
        capture_log(fn ->
          GenServer.cast(relay, {:broadcast, :not_a_topic, message})
          :ok = GenServer.call(relay, :sync)
        end)

      assert log =~ "Feed relay could not broadcast"
      assert Process.alive?(relay)

      GenServer.cast(relay, {:broadcast, Feed.topic(site), message})
      :ok = GenServer.call(relay, :sync)
      assert_received ^message
    end
  end

  defp publish_from_bare_process!(site, id) do
    test = self()

    spawn(fn ->
      publish!(site, id)
      send(test, :published)
    end)

    assert_receive :published, 5_000
  end

  # Until `pid` waits on the shared owner's busy connection (its innermost
  # frame is the holder's checkout call, not a call to the ownership
  # manager): the moment the owner has to go away for the checkout to exit,
  # not merely fail.
  defp wait_until_checking_out(pid, attempts \\ 500) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    cond do
      match?([{DBConnection.Holder, :checkout_call, _, _} | _], stack) ->
        :ok

      attempts == 0 ->
        flunk("the publisher never waited on a connection")

      true ->
        Process.sleep(10)
        wait_until_checking_out(pid, attempts - 1)
    end
  end

  # Feed event ids in the mailbox, oldest first.
  defp drain do
    receive do
      {:kiln_feed, %Event{id: id}} -> [id | drain()]
    after
      0 -> []
    end
  end

  # The test may have resumed it already, or failed before; resuming a
  # running process is harmless, a dead one is not worth failing on_exit for.
  defp resume(relay) do
    :sys.resume(relay)
  catch
    :exit, _reason -> :ok
  end
end
