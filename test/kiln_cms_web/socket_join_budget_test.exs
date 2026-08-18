defmodule KilnCMSWeb.SocketJoinBudgetTest do
  @moduledoc """
  The per-address budget on `/ws/gql`, `/ws/bridge` and `/ws/collab` connects
  — the `/ws/*` half of threat-model item 10's remaining gap after #1183
  narrowed it to `/live` root joins first.

  `config/test.exs` raises all three buckets to a million so the rest of the
  suite never sees them; every test here lowers the one it needs back through
  the same override `RateLimit.limits/0` reads, and restores it after.
  `async: false` for that, and because the Hammer ETS table is one per node.

  Per-socket wiring (that `connect/1,2,3` actually calls `charge/2`, first,
  ahead of tenant/token checks) is proved in each socket's own test file
  (`GraphqlSocketTest`, `BridgeSocketTest`, `CollabChannelTest`); this file
  covers the shared mechanics once instead of three times.
  """
  use ExUnit.Case, async: false

  import KilnCMS.RateLimitHelpers, only: [client_address: 0, put_limit: 2, spent: 2]

  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.RateLimit
  alias KilnCMSWeb.SocketJoinBudget

  @moduletag :capture_log

  setup do
    RateLimitHelpers.restore_limits_on_exit()
  end

  defp connect_info(address),
    do: %{peer_data: %{address: address, port: 111, ssl_cert: nil}, x_headers: []}

  describe "the buckets" do
    test "gql_join, bridge_join and collab_join exist with flood-ceiling defaults, sized like live_join" do
      for bucket <- [:gql_join, :bridge_join, :collab_join] do
        assert {limit, scale} = RateLimit.default_limits()[bucket]
        assert scale == :timer.minutes(1)
        # A ceiling, not a cap — same range `LiveJoinBudgetTest` asserts for
        # `:live_join`.
        assert limit >= 200 and limit <= 600
      end
    end
  end

  describe "charge/2" do
    test "connects under the limit succeed; the one over it is refused" do
      put_limit(:gql_join, 3)
      address = client_address()

      for _ <- 1..3 do
        assert :ok = SocketJoinBudget.charge(:gql_join, connect_info(address))
      end

      assert :error = SocketJoinBudget.charge(:gql_join, connect_info(address))
    end

    test "the refusal is keyed on the client address — another address is unaffected" do
      put_limit(:bridge_join, 1)
      address_a = client_address()
      address_b = client_address()

      assert :ok = SocketJoinBudget.charge(:bridge_join, connect_info(address_a))
      assert :error = SocketJoinBudget.charge(:bridge_join, connect_info(address_a))

      # B has spent nothing.
      assert :ok = SocketJoinBudget.charge(:bridge_join, connect_info(address_b))
    end

    test "the three socket buckets are independent — spending one leaves the others untouched" do
      put_limit(:gql_join, 1)
      put_limit(:collab_join, 1)
      address = client_address()

      assert :ok = SocketJoinBudget.charge(:gql_join, connect_info(address))
      assert :error = SocketJoinBudget.charge(:gql_join, connect_info(address))

      # Same address, a different bucket: still has its own budget.
      assert :ok = SocketJoinBudget.charge(:collab_join, connect_info(address))
    end

    test "a connect_info with neither :peer_data nor :x_headers shares the unknown-client bucket, rather than crashing" do
      # The unknown-client key is node-wide and other socket tests in this
      # window charge it too (a bare `connect/2` has no address), so a lowered
      # limit here would see their spend as its own. Assert the DELTA on that
      # key instead — the charge landed on the shared bucket, and did not crash.
      before = spent(:gql_join, "unknown")

      assert :ok = SocketJoinBudget.charge(:gql_join, %{})
      assert spent(:gql_join, "unknown") == before + 1
    end
  end
end
