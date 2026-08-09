defmodule KilnCMSWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use KilnCMSWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint KilnCMSWeb.Endpoint

      use KilnCMSWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import KilnCMSWeb.ConnCase
    end
  end

  setup tags do
    KilnCMS.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Point `conn` at an organization's own host, so the request resolves to that
  tenant (epic #336).

  Here rather than re-derived per test file: this one line encodes the
  subdomain-tenancy contract — an org's `slug` under `KilnCMSWeb.Tenant.base_host/0`
  — and every copy of it has to be found by grep the next time that spelling
  changes.
  """
  @spec org_conn(Plug.Conn.t(), KilnCMS.Accounts.Organization.t()) :: Plug.Conn.t()
  def org_conn(conn, org), do: %{conn | host: "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"}

  @doc """
  Give `conn` a client address no other request in the run will reuse, so a
  per-IP rate limiter cannot couple two unrelated tests.

  Three octets of the unique integer, not one. Three test files each had their
  own copy spelled `rem(System.unique_integer([:positive]), 250)`, which is 250
  addresses — and 250 is small enough that a file making twenty requests has a
  **54% chance** of drawing the same address twice (birthday). When it happens
  the second request shares a bucket with the first and comes back `429`, which
  surfaces as `expected response with status 200, got: 429` inside whatever the
  test was actually asserting. That is not a hypothetical: it broke `main` on
  2026-08-09 (`KilnCMSWeb.FormEmbedTest`, run 31287147181).

  The files also hand-separated themselves by second octet (127.1/127.2/127.3)
  to avoid colliding with *each other* — unnecessary once the space is wide
  enough, and a thing every new file would have had to know to do.

  `127.0.0.0/8` throughout: loopback is inert, and `RateLimit.client_key/1`
  treats it as any other address.
  """
  @spec unique_ip(Plug.Conn.t()) :: Plug.Conn.t()
  def unique_ip(conn) do
    n = System.unique_integer([:positive])

    # 254 × 250 × 250 ≈ 15.9M addresses, and `unique_integer` is monotonic per
    # VM, so the low octets vary fastest and a run never wraps in practice.
    %{
      conn
      | remote_ip: {127, rem(div(n, 62_500), 254) + 1, rem(div(n, 250), 250), rem(n, 250) + 1}
    }
  end

  @doc """
  Render `view` until `substring` is present (or absent, with `present?: false`),
  or fail after `timeout_ms`.

  For anything that arrives over PubSub — a Presence join/leave, a broadcast
  patch — where the write and the render are in different processes and nothing
  in the test can synchronise them.

  Three files carried a copy of this budgeted `tries \\\\ 40` at `sleep(25)`:
  **one second**, which is fine on a developer's machine and not fine on a
  loaded CI runner. It failed `main` on 2026-08-09 (`PreviewLiveTest`, "leaving
  drops a viewer") on a presence-leave diff that took longer than a second.

  Expressed as a deadline rather than an iteration count, so shortening the poll
  interval later cannot silently shrink the budget — which is how a `tries`
  count decays into a flake. A generous timeout costs nothing when the condition
  is met: the loop returns on the first successful render.
  """
  @spec eventually(term(), String.t(), boolean(), pos_integer()) :: String.t()
  def eventually(view, substring, present? \\ true, timeout_ms \\ 5_000) do
    poll(view, substring, present?, System.monotonic_time(:millisecond) + timeout_ms, timeout_ms)
  end

  defp poll(view, substring, present?, deadline, timeout_ms) do
    html = Phoenix.LiveViewTest.render(view)

    cond do
      String.contains?(html, substring) == present? ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        ExUnit.Assertions.flunk(
          "expected #{inspect(substring)} #{if present?, do: "in", else: "gone from"} " <>
            "the render within #{timeout_ms}ms"
        )

      true ->
        Process.sleep(25)
        poll(view, substring, present?, deadline, timeout_ms)
    end
  end
end
