defmodule KilnCMS.Security.CrawlerSightingStoreTest do
  @moduledoc """
  The shared first sightings behind `CrawlerVerification.listing_overdue?/3`
  (#2852): one upsert that keeps the earliest live sighting, an expiry each
  question moves on, a prune, and a table no person reads.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.CrawlerSightingStore, as: Store

  @ttl :timer.hours(48)

  defp key, do: "inet:198.51.100.#{System.unique_integer([:positive])}"
  defp wall, do: System.system_time(:millisecond)

  describe "record/3" do
    test "the first record dates the sighting by the database clock" do
      k = key()

      assert {:ok, first_seen} = Store.record(k, :duckduckgo, @ttl)
      assert_in_delta first_seen, wall(), :timer.minutes(1)
      assert {^first_seen, ttl} = Store.fetch(k, :duckduckgo)
      assert_in_delta ttl, @ttl, :timer.minutes(1)
    end

    test "a later record keeps the first sighting and moves the expiry on" do
      k = key()
      Store.put(k, :duckduckgo, wall() - :timer.hours(30), 60_000)

      assert {:ok, first_seen} = Store.record(k, :duckduckgo, @ttl)
      assert first_seen <= wall() - :timer.hours(30)
      assert {^first_seen, ttl} = Store.fetch(k, :duckduckgo)
      assert ttl > :timer.hours(47)
    end

    test "a lapsed sighting starts again" do
      k = key()
      old = wall() - :timer.hours(30)
      Store.put(k, :duckduckgo, old, -1_000)

      assert {:ok, first_seen} = Store.record(k, :duckduckgo, @ttl)
      assert first_seen > old
    end

    test "each engine has a sighting of its own" do
      k = key()
      Store.put(k, :duckduckgo, wall() - :timer.hours(30), @ttl)

      assert {:ok, first_seen} = Store.record(k, :google, @ttl)
      assert_in_delta first_seen, wall(), :timer.minutes(1)
    end

    test "inside a transaction nothing is written" do
      k = key()

      assert {:ok, {:unavailable, :in_transaction}} =
               Repo.transaction(fn -> Store.record(k, :duckduckgo, @ttl) end)

      assert Store.fetch(k, :duckduckgo) == nil
    end

    test "a process the database will not serve gets :unavailable, never a raise" do
      parent = self()
      ref = make_ref()
      spawn(fn -> send(parent, {ref, Store.record(key(), :duckduckgo, @ttl)}) end)

      assert_receive {^ref, {:unavailable, %DBConnection.OwnershipError{}}}, 5_000
    end
  end

  describe "prune" do
    test "deletes lapsed sightings and keeps live ones" do
      lapsed = key()
      live = key()
      Store.put(lapsed, :duckduckgo, wall(), -1_000)
      Store.put(live, :duckduckgo, wall(), @ttl)

      assert Store.prune() >= 1
      assert Store.fetch(lapsed, :duckduckgo) == nil
      assert {_first_seen, _ttl} = Store.fetch(live, :duckduckgo)
    end

    test "the scheduled prune is the system actor's, and nobody reads a sighting" do
      lapsed = key()
      Store.put(lapsed, :duckduckgo, wall(), -1_000)

      assert Security.prune_crawler_sightings!(actor: KilnCMS.SystemActor.new(:operator)) >= 1
      assert Store.fetch(lapsed, :duckduckgo) == nil

      admin = %KilnCMS.Accounts.User{id: Ecto.UUID.generate(), role: :admin}

      assert {:error, %Ash.Error.Forbidden{}} = Security.prune_crawler_sightings(actor: admin)
      assert {:error, %Ash.Error.Forbidden{}} = Security.prune_crawler_sightings()

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.prune_crawler_sightings(actor: KilnCMS.SystemActor.new(:security))

      # A read policy that forbids filters rather than raising: nobody sees
      # a row, not even the one just written.
      Store.put(key(), :duckduckgo, wall(), @ttl)
      assert {:ok, []} = Security.list_crawler_sightings(actor: admin)

      assert {:ok, []} =
               Security.list_crawler_sightings(actor: KilnCMS.SystemActor.new(:operator))
    end
  end
end
