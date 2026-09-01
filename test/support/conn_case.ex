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
    # Every ConnCase test gets its own peer + `remote_ip` by default (#936).
    # Without this, `build_conn/0`'s loopback address makes every file charge
    # the same rate-limit buckets, and any test that *reads* a counter is
    # coupled to the rest of the suite. Opt back into the shared bucket with
    # `loopback_conn/0`.
    {conn, _ip} = KilnCMS.RateLimitHelpers.client_conn(Phoenix.ConnTest.build_conn())
    {:ok, conn: conn}
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
  A bare `Phoenix.ConnTest.build_conn/0` peering from loopback — the shared
  rate-limit bucket. Opt in only when a test *needs* every request to share one
  address (e.g. proving a per-account budget is not per-IP).
  """
  @spec loopback_conn() :: Plug.Conn.t()
  def loopback_conn, do: Phoenix.ConnTest.build_conn()

  @doc """
  Give `conn` a client address no other request in the run will reuse, so a
  per-IP rate limiter cannot couple two unrelated tests.

  Delegates to `KilnCMS.RateLimitHelpers.client_conn/1` (#936): one scheme for
  every file, including the ones that used to draw from 250 loopback addresses
  with `rem(unique_integer, 250)` and collide under load.
  """
  @spec unique_ip(Plug.Conn.t()) :: Plug.Conn.t()
  def unique_ip(conn) do
    {conn, _ip} = KilnCMS.RateLimitHelpers.client_conn(conn)
    conn
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

  The deadline loop itself lives in `KilnCMS.Test.Eventually` (#1349) — reach
  for it directly when the condition is not a substring of a LiveView render.
  """
  @spec eventually(term(), String.t(), boolean(), pos_integer()) :: String.t()
  def eventually(view, substring, present? \\ true, timeout_ms \\ 5_000) do
    KilnCMS.Test.Eventually.eventually(
      fn ->
        html = Phoenix.LiveViewTest.render(view)
        String.contains?(html, substring) == present? && html
      end,
      timeout_ms: timeout_ms,
      message: fn ->
        "expected #{inspect(substring)} #{if present?, do: "in", else: "gone from"} " <>
          "the render within #{timeout_ms}ms"
      end
    )
  end
end
