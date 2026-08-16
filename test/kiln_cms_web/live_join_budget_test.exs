defmodule KilnCMSWeb.LiveJoinBudgetTest do
  @moduledoc """
  The per-address budget on `/live` root joins (#1183).

  `config/test.exs` raises `:live_join` to a million so the rest of the suite
  never sees it; every test here lowers it back through the same override
  `RateLimit.limits/0` reads, and restores it after. `async: false` for that,
  and because the Hammer ETS table is one per node.

  Each test uses an address of its own (`RateLimitHelpers.client_conn/1`), so
  what one spends another never sees; the bucket is a fixed one-minute window,
  so a fresh address is the only reliable reset.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]
  import Phoenix.LiveViewTest

  alias KilnCMSWeb.LiveJoinBudget
  alias KilnCMSWeb.RateLimit

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:kiln_cms, RateLimit, [])
    on_exit(fn -> Application.put_env(:kiln_cms, RateLimit, previous) end)
    :ok
  end

  defp put_live_join_limit(limit) do
    current = Application.get_env(:kiln_cms, RateLimit, [])

    limits =
      current |> Keyword.get(:limits, %{}) |> Map.put(:live_join, {limit, :timer.minutes(1)})

    Application.put_env(:kiln_cms, RateLimit, Keyword.put(current, :limits, limits))
  end

  # A public, anonymous-reachable LiveView root — the highest-volume surface.
  @path "/sign-in"

  # What `Phoenix.LiveView.Channel` does with a 4xx raised during mount: replies
  # `{:error, %{reason: "reload", status: 429, …}}` and stops — no mount, no
  # render, no process. `Phoenix.LiveViewTest.live/2` exits with that reply.
  defp assert_refused(conn) do
    assert {%{reason: "reload", status: 429}, _} =
             catch_exit(live(conn, @path))
  end

  describe "the budget" do
    test "the bucket exists with a flood-ceiling default, sized like :delivery" do
      assert LiveJoinBudget.bucket() == :live_join
      assert {limit, scale} = RateLimit.default_limits()[:live_join]
      assert scale == :timer.minutes(1)
      # A ceiling, not a cap: well above what a NAT full of editors reloading
      # pages produces, well below what a scripted replay produces.
      assert limit >= 200 and limit <= 600
    end

    test "root joins under the limit connect; the one over it is refused with a 429 reload",
         %{conn: conn} do
      put_live_join_limit(3)
      {conn, _ip} = client_conn(conn)

      # Three joins from this address are fine…
      for _ <- 1..3 do
        assert {:ok, _view, _html} = live(conn, @path)
      end

      # …the fourth is refused before mount, as the 4xx-during-mount shape the
      # channel turns into a client `reload` reply carrying the status. The
      # test client surfaces that reply as an exit.
      assert_refused(conn)
    end

    test "the refusal is keyed on the client address — another address is unaffected",
         %{conn: conn} do
      put_live_join_limit(1)
      {conn_a, _} = client_conn(conn)
      {conn_b, _} = client_conn(conn)

      assert {:ok, _, _} = live(conn_a, @path)
      assert_refused(conn_a)

      # B has spent nothing.
      assert {:ok, _, _} = live(conn_b, @path)
    end

    test "the dead render is not charged — only the connected root join is", %{conn: conn} do
      put_live_join_limit(1)
      {conn, _ip} = client_conn(conn)

      # Any number of plain HTTP renders…
      for _ <- 1..3, do: assert(html_response(get(conn, @path), 200))

      # …and the first connected join still goes through: nothing above spent
      # the bucket. (The second is refused, proving the limit was live.)
      assert {:ok, _, _} = live(conn, @path)
      assert_refused(conn)
    end

    test "the error carries a 429 so the channel replies reload rather than crashing" do
      error = LiveJoinBudget.TooManyJoinsError.exception(retry_after_ms: 1234)
      assert Plug.Exception.status(error) == 429
      assert error.retry_after_ms == 1234
      assert Exception.message(error) =~ "join budget"
    end
  end

  describe "the hook is attached to every Kiln LiveView, before the route guard" do
    test "KilnCMSWeb.live_view/0 declares it first" do
      # `on_mount` order is the declaration order; a join the guard refuses as
      # url-less must still have been charged, so the budget has to run first.
      hooks = KilnCMSWeb.SignInLive.__live__().lifecycle.mount |> Enum.map(& &1.id)

      assert {LiveJoinBudget, :default} in hooks
      assert {KilnCMSWeb.LiveRouteGuard, :default} in hooks

      budget_at = Enum.find_index(hooks, &(&1 == {LiveJoinBudget, :default}))
      guard_at = Enum.find_index(hooks, &(&1 == {KilnCMSWeb.LiveRouteGuard, :default}))
      assert budget_at < guard_at
    end
  end
end
