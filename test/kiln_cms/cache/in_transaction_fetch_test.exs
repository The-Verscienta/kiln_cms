defmodule KilnCMS.Cache.InTransactionFetchTest do
  @moduledoc """
  A cache fetch from a process that holds a database connection computes a
  miss in that process and stores nothing (#2823).

  On the courier the fallback needs a second connection while the caller holds
  its first. Under the SQL sandbox the courier is routed to the caller's one
  connection, which the caller holds while it waits for the courier, so the
  checkout is dropped after about a second; case one below raised that
  `DBConnection.ConnectionError` before the fix.

  Every key is unique to its test, but another async test's full clear
  (`Cache.bust_published/0`, e.g. on any media write) can still empty the
  store, so the cases that read an entry back are in
  `KilnCMS.Cache.InTransactionFetchStoreTest` (`async: false`) below.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Cache
  alias KilnCMS.Repo

  @ttl :timer.minutes(1)

  defp key, do: "in-transaction-fetch:#{System.unique_integer([:positive])}"

  defp in_transaction(fun) do
    {:ok, value} = Repo.transaction(fun)
    value
  end

  describe "inside a transaction" do
    test "a miss that reads the database is computed on the caller's connection" do
      key = key()

      assert in_transaction(fn ->
               Cache.fetch(key, @ttl, fn -> Repo.query!("select 1").rows end)
             end) == [[1]]
    end

    test "a miss stores no entry" do
      key = key()

      assert in_transaction(fn -> Cache.fetch(key, @ttl, fn -> :computed end) end) ==
               :computed

      assert Cache.peek(key) == nil
    end

    test "a miss runs the fallback in the caller, not on a courier process" do
      test_pid = self()

      assert in_transaction(fn -> Cache.fetch(key(), @ttl, fn -> self() end) end) == test_pid
    end

    test "a raising fallback raises in the caller" do
      assert_raise RuntimeError, "boom", fn ->
        Repo.checkout(fn -> Cache.fetch(key(), @ttl, fn -> raise "boom" end) end)
      end
    end

    test "a published-content miss is computed in the caller, counted, and not stored" do
      org_id = Ash.UUID.generate()
      slug = "in-transaction-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "in-transaction-fetch-#{System.unique_integer([:positive])}"

      # Async neighbours emit the same event from their own processes; keep
      # only the ones this process emits.
      :telemetry.attach(
        handler_id,
        [:kiln_cms, :cache, :content],
        fn _name, _measurements, %{result: result}, _config ->
          if self() == test_pid, do: send(test_pid, {:cache_result, result})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert in_transaction(fn ->
               Cache.fetch_published(org_id, "page", slug, "en", fn ->
                 Repo.query!("select 1").rows
               end)
             end) == [[1]]

      assert_received {:cache_result, :miss}

      refute Cache.fetch_published(org_id, "page", slug, "en", fn -> nil end),
             "the in-transaction miss must not have been stored"
    end
  end
end

defmodule KilnCMS.Cache.InTransactionFetchStoreTest do
  @moduledoc """
  The cases of `KilnCMS.Cache.InTransactionFetchTest` that read an entry back
  from the shared store. `async: false`: an async test's full clear
  (`Cache.bust_published/0`) between the put and the read would fail them,
  which a unique key does not prevent (as `KilnCMS.CacheTest`).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.Repo

  @ttl :timer.minutes(1)

  defp key, do: "in-transaction-fetch-store:#{System.unique_integer([:positive])}"

  defp in_transaction(fun) do
    {:ok, value} = Repo.transaction(fun)
    value
  end

  describe "inside a transaction" do
    test "a cached value is served without running the fallback" do
      key = key()
      Cache.put(key, :cached, @ttl)

      assert in_transaction(fn ->
               Cache.fetch(key, @ttl, fn -> flunk("a hit must not run the fallback") end)
             end) == :cached
    end
  end

  describe "outside a transaction" do
    test "a miss runs on the courier and is stored" do
      key = key()
      test_pid = self()

      runner = Cache.fetch(key, @ttl, fn -> self() end)

      assert is_pid(runner)
      refute runner == test_pid
      assert Cache.peek(key) == runner
    end
  end
end
