defmodule KilnCMSWeb.Plugs.SetTenant do
  @moduledoc """
  Resolves the request's organization from its host and sets it as the Ash tenant
  (epic #336).

  Runs in the endpoint (after `SetLocale`, before the router) so it precedes every
  pipeline. Calling `Ash.PlugHelpers.set_tenant/2` makes the headless
  GraphQL/JSON:API surfaces (`AshGraphql.Plug`, `AshJsonApi`) tenant-scoped with no
  resolver changes, and `assign(:current_org, org)` gives the controllers /
  LiveViews the org for their reads (see `KilnCMSWeb.Tenant`).

  Resolution (subdomain → custom domain → default org) is `KilnCMSWeb.Tenant.resolve_org/1`,
  shared with the LiveView `:assign_current_org` on_mount hook. It always yields an
  org, so a bare-host / `localhost` request transparently serves the default org —
  the non-breaking single-host behavior.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    org = KilnCMSWeb.Tenant.resolve_org(conn.host)

    conn
    |> Ash.PlugHelpers.set_tenant(org)
    |> assign(:current_org, org)
  end
end
