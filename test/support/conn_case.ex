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
end
