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

  # No database here: the publisher's anonymous-view read of an event without
  # an audience (#2275) fails, is logged, and hides the event from SSE
  # streams; the relay's delivery, which is what these tests are about, is
  # unaffected.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias KilnCMS.Delivery.Feed
  alias KilnCMS.Delivery.Feed.Event
  alias KilnCMS.Delivery.Feed.Relay

  # A site of its own per test: nothing else publishes to it.
  setup do
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
