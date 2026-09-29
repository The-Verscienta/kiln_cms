defmodule KilnCMS.Accounts.ThrottleStoreTest do
  @moduledoc """
  The shared counter behind every credential budget (#1619, threat-model
  residual 10): atomic, bounded, expiring, and never charged inside a
  transaction. The cross-node proof is `ThrottleStorePeerTest`; the fail
  direction is `ThrottleStoreFallbackTest`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Repo

  # Windows are epoch-aligned (by the database clock, or Hammer's on the
  # fallback), so two hits a minute-wide test makes can land either side of a
  # boundary and see two windows — a flake that failed CI at 17:13:00.05. A
  # century-wide window's current one runs 1970–2070: no test run straddles it.
  @window :timer.hours(24 * 365 * 100)

  defp bucket, do: "test:#{System.unique_integer([:positive])}"

  describe "a fixed window" do
    test "admits `limit` and refuses the rest, with the time left in the window" do
      b = bucket()
      scale = @window

      assert {:allow, 1} = ThrottleStore.hit(b, "k", scale, 3)
      assert {:allow, 2} = ThrottleStore.hit(b, "k", scale, 3)
      assert {:allow, 3} = ThrottleStore.hit(b, "k", scale, 3)
      assert {:deny, retry_after} = ThrottleStore.hit(b, "k", scale, 3)

      assert retry_after > 0 and retry_after <= scale
    end

    test "a cost is charged whole" do
      b = bucket()

      assert {:allow, 4} = ThrottleStore.hit(b, "k", @window, 5, 4)
      assert {:deny, _} = ThrottleStore.hit(b, "k", @window, 5, 2)
    end

    test "keys and buckets are independent" do
      b = bucket()

      assert {:allow, 1} = ThrottleStore.hit(b, "a", @window, 1)
      assert {:deny, _} = ThrottleStore.hit(b, "a", @window, 1)
      assert {:allow, 1} = ThrottleStore.hit(b, "b", @window, 1)
      assert {:allow, 1} = ThrottleStore.hit(bucket(), "a", @window, 1)
    end

    test "a simultaneous burst admits exactly the budget" do
      b = bucket()

      allowed =
        1..30
        |> Task.async_stream(fn _ -> ThrottleStore.hit(b, "burst", @window, 7) end,
          max_concurrency: 30
        )
        |> Enum.count(&match?({:ok, {:allow, _}}, &1))

      assert allowed == 7
      assert ThrottleStore.spent(b, "burst") == 30
    end

    test "the next window starts from zero" do
      b = bucket()
      scale = 200

      # Start just after a boundary so the three charges share a window.
      wait_for_window_start(scale)
      assert {:allow, 1} = ThrottleStore.hit(b, "k", scale, 1)
      assert {:deny, retry_after} = ThrottleStore.hit(b, "k", scale, 1)

      Process.sleep(retry_after + 20)
      assert {:allow, 1} = ThrottleStore.hit(b, "k", scale, 1)
    end

    test "forget/2 clears every window of the key" do
      b = bucket()

      assert {:allow, 1} = ThrottleStore.hit(b, "k", @window, 1)
      assert {:deny, _} = ThrottleStore.hit(b, "k", @window, 1)
      assert :ok = ThrottleStore.forget(b, "k")
      assert {:allow, 1} = ThrottleStore.hit(b, "k", @window, 1)
    end
  end

  describe "the key space is bounded and expires" do
    test "a key is stored as a fixed 32-byte hash, whatever was submitted" do
      b = bucket()
      huge = String.duplicate("attacker-chosen@example.com", 40_000)

      ThrottleStore.hit(b, huge, :timer.minutes(15), 10)
      ThrottleStore.hit(b, "short", :timer.minutes(15), 10)

      %{rows: rows} =
        Repo.query!(
          "SELECT key_hash, octet_length(key_hash) FROM throttle_counters WHERE bucket = $1",
          [b]
        )

      assert Enum.map(rows, &List.last/1) == [32, 32]
      refute Enum.any?(rows, fn [hash, _] -> :binary.match(hash, "short") != :nomatch end)
    end

    test "a row expires when its window closes, by the database clock" do
      b = bucket()
      scale = :timer.minutes(15)

      ThrottleStore.hit(b, "k", scale, 10)

      %{rows: [[seconds_left]]} =
        Repo.query!(
          "SELECT extract(epoch FROM expires_at - (clock_timestamp() AT TIME ZONE 'UTC'))::float8 FROM throttle_counters WHERE bucket = $1",
          [b]
        )

      assert seconds_left > 0 and seconds_left <= scale / 1000
    end

    test "prune deletes closed windows and keeps open ones" do
      closed = bucket()
      open = bucket()

      ThrottleStore.hit(closed, "k", 1, 10)
      ThrottleStore.hit(open, "k", :timer.minutes(15), 10)
      Process.sleep(10)

      assert ThrottleStore.prune() >= 1
      assert ThrottleStore.spent(closed, "k") == 0
      assert ThrottleStore.spent(open, "k") == 1
    end

    test "the scheduled prune is the system actor's, and nobody reads a counter" do
      closed = bucket()
      ThrottleStore.hit(closed, "k", 1, 10)
      Process.sleep(10)

      assert KilnCMS.Accounts.prune_throttle_counters!(actor: KilnCMS.SystemActor.new(:operator)) >=
               1

      admin = %KilnCMS.Accounts.User{id: Ecto.UUID.generate(), role: :admin}

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.Accounts.prune_throttle_counters(actor: admin)

      # A read policy that forbids filters rather than raising: the admin sees
      # no rows, not even the one just written.
      ThrottleStore.hit(bucket(), "k", :timer.minutes(15), 10)
      assert {:ok, []} = KilnCMS.Accounts.list_throttle_counters(actor: admin)
    end
  end

  describe "never inside a transaction" do
    test "a charge inside a transaction raises rather than being refundable" do
      b = bucket()

      assert_raise ArgumentError, ~r/inside a transaction/, fn ->
        Repo.transaction(fn -> ThrottleStore.hit(b, "k", @window, 1) end)
      end

      assert ThrottleStore.spent(b, "k") == 0
    end

    test "a forgiveness inside one is fine" do
      b = bucket()
      ThrottleStore.hit(b, "k", @window, 1)

      assert {:ok, :ok} = Repo.transaction(fn -> ThrottleStore.forget(b, "k") end)
      assert ThrottleStore.spent(b, "k") == 0
    end
  end

  defp wait_for_window_start(scale) do
    into = rem(System.system_time(:millisecond), scale)
    if into > scale / 4, do: Process.sleep(scale - into + 5)
  end
end

defmodule KilnCMS.Accounts.ThrottleStoreFallbackTest do
  @moduledoc """
  The fail direction (#1619): when the database cannot answer, a budget is
  counted on the node — neither admitted without limit nor refused outright.

  Not a `DataCase`, deliberately: with no sandbox checked out, every query this
  process makes fails with `DBConnection.OwnershipError`, which is the store
  being unreachable as far as `ThrottleStore` can tell. (A sync `DataCase` runs
  the sandbox in shared mode, where every process reaches the database.) Sync,
  because it reads the node-wide fallback table and its log throttle.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Accounts.ThrottleStore.Local

  # A window no test run straddles — see ThrottleStoreTest.
  @window :timer.hours(24 * 365 * 100)

  defp without_database(fun), do: fun.()

  setup do
    # The sync DataCase test before this one ran the sandbox as
    # `{:shared, owner}`. The ownership manager drops that mode when it sees the
    # owner go down, but asynchronously: a query sent first reaches the dying
    # owner's connection and exits with "owner exited" rather than raising
    # `OwnershipError` (failed CI on #1686). Setting manual mode is a call to
    # the manager, so "no checkout" means "unreachable" before the first hit.
    Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)

    # Re-arm the once-a-minute log so this test sees its own line.
    :ets.match_delete(Local, {{:fallback_logged, :_}, :_, :_})
    :ok
  end

  test "an unreachable store degrades to a per-node budget, and says so" do
    b = "test:fallback:#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        results =
          without_database(fn ->
            for _ <- 1..5, do: ThrottleStore.hit(b, "k", @window, 3)
          end)

        # Not fail-open: the budget still holds. Not fail-closed: the first
        # three are admitted, exactly as the shared store would have.
        assert [{:allow, 1}, {:allow, 2}, {:allow, 3}, {:deny, _}, {:deny, _}] = results
      end)

    assert log =~ "Auth throttle store unavailable"
    assert log =~ "on this node only"

    # Nothing reached the shared table.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(KilnCMS.Repo)
    assert ThrottleStore.spent(b, "k") == 0
    :ok = Ecto.Adapters.SQL.Sandbox.checkin(KilnCMS.Repo)

    # And forget/2 clears the node's copy too, even with no database.
    assert :ok = without_database(fn -> ThrottleStore.forget(b, "k") end)

    assert {:allow, 1} =
             without_database(fn -> ThrottleStore.hit(b, "k", @window, 3) end)
  end

  test "the fallback log is throttled to once a minute per node" do
    b = "test:fallback:#{System.unique_integer([:positive])}"

    # The log throttle is Hammer's epoch-aligned minute: four hits either side
    # of a minute boundary would rightly log twice.
    wait_clear_of_minute_boundary()

    log =
      capture_log(fn ->
        without_database(fn ->
          for _ <- 1..4, do: ThrottleStore.hit(b, "k", @window, 100)
        end)
      end)

    assert length(String.split(log, "Auth throttle store unavailable")) == 2
  end

  defp wait_clear_of_minute_boundary do
    left = :timer.minutes(1) - rem(System.system_time(:millisecond), :timer.minutes(1))
    if left < 1_000, do: Process.sleep(left + 5)
  end
end

defmodule KilnCMS.Accounts.ThrottleStorePeerTest do
  @moduledoc """
  The budgets hold across nodes (#1619): two real BEAM nodes (`:peer`), each
  with its own `KilnCMS.Repo` pool and its own node-local fallback table,
  charging the same Postgres table. Before #1619 each would have granted the
  full budget, so two nodes meant twice the guesses.

  Outside the sandbox by necessity — a peer's pool cannot join this node's
  sandbox transaction — so every row these tests write is committed, keyed on
  values minted here, and deleted again in `on_exit`.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.ThrottleStore

  @moduletag timeout: 120_000

  setup_all do
    repo_config =
      KilnCMS.Repo.config()
      |> Keyword.drop([:pool, :ownership_timeout, :queue_target, :queue_interval])
      |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: 4, log: false)

    nodes = for _ <- 1..2, do: start_node(repo_config)
    %{nodes: nodes}
  end

  test "the second-factor budget holds across two nodes", %{nodes: [a, b] = nodes} do
    user_id = Ecto.UUID.generate()
    on_exit(fn -> forget(nodes, "2fa", AccountThrottle.digest(user_id)) end)

    # The shipped budget: the peers load no test config.
    budget = AccountThrottle.defaults()[:second_factor_budget]
    on_a = budget - 2

    for _ <- 1..on_a,
        do: assert(call(a, AccountThrottle, :consume_second_factor, [user_id]) == :allow)

    for _ <- 1..2,
        do: assert(call(b, AccountThrottle, :consume_second_factor, [user_id]) == :allow)

    assert {:deny, _} = call(b, AccountThrottle, :consume_second_factor, [user_id])
    assert {:deny, _} = call(a, AccountThrottle, :consume_second_factor, [user_id])

    # A verified code on one node releases the budget on the other.
    assert :ok = call(b, AccountThrottle, :forgive_second_factor, [user_id])
    assert :allow = call(a, AccountThrottle, :consume_second_factor, [user_id])
  end

  test "a simultaneous burst from both nodes admits exactly the budget", %{nodes: nodes} do
    identifier = "peer-burst-#{System.unique_integer([:positive])}@example.com"
    on_exit(fn -> forget(nodes, "signin", AccountThrottle.digest(identifier)) end)

    budget = AccountThrottle.defaults()[:budget]

    allowed =
      nodes
      |> Enum.flat_map(&List.duplicate(&1, budget))
      |> Task.async_stream(&call(&1, AccountThrottle, :consume, [identifier]),
        max_concurrency: 2 * budget,
        timeout: 30_000
      )
      |> Enum.count(&(&1 == {:ok, :allow}))

    assert allowed == budget
  end

  test "the per-IP :auth bucket holds across two nodes", %{nodes: [a, b] = nodes} do
    # Not an address, and it need not be: the key is opaque to the store, and
    # this one cannot collide with any other test's.
    ip = "peer-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> forget(nodes, "ip:auth", ip) end)

    {limit, _scale} = KilnCMSWeb.RateLimit.default_limits()[:auth]
    half = div(limit, 2)

    for _ <- 1..half, do: assert(call(a, KilnCMSWeb.RateLimit, :check, [:auth, ip]) == :allow)

    for _ <- 1..(limit - half),
        do: assert(call(b, KilnCMSWeb.RateLimit, :check, [:auth, ip]) == :allow)

    assert {:deny, _} = call(a, KilnCMSWeb.RateLimit, :check, [:auth, ip])
    assert {:deny, _} = call(b, KilnCMSWeb.RateLimit, :check, [:auth, ip])
  end

  # ---------------------------------------------------------------------------

  defp start_node(repo_config) do
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io, args: args, wait_boot: 60_000})
    on_exit(fn -> stop_node(peer) end)

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ecto_sql], 60_000)
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:postgrex], 60_000)
    :ok = :peer.call(peer, Application, :put_env, [:kiln_cms, KilnCMS.Repo, repo_config])

    # Under `kernel_safe_sup` — the kernel's own home for children like these —
    # because a `start_link` from `:peer.call/5` links to the call's process,
    # and a supervisor exits with its parent even when the parent exits
    # normally. Child specs are plain data, so they cross the wire.
    for spec <- [KilnCMS.Repo.child_spec([]), ThrottleStore.Local.child_spec([])] do
      {:ok, _} = :peer.call(peer, :supervisor, :start_child, [:kernel_safe_sup, spec], 60_000)
    end

    peer
  end

  defp stop_node(peer) do
    :peer.stop(peer)
  catch
    :exit, _already_down -> :ok
  end

  defp call(peer, mod, fun, args), do: :peer.call(peer, mod, fun, args, 30_000)

  # The rows are committed (see the moduledoc), so delete them — through a
  # peer, since this node's own Repo is the sandbox. This module's code is not
  # on the peers, so it has to be an MFA rather than a closure.
  defp forget([node | _], bucket, key),
    do: :ok = call(node, ThrottleStore, :forget, [bucket, key])
end
