defmodule KilnDepFixture.HookPlug do
  @moduledoc """
  A plain Plug mounted through `c:Kiln.Plugin.plug_routes/0` (#2272). A
  Phoenix controller is a Plug whose opts is the action atom; this is the same
  shape with nothing but `plug` underneath it.

    * `:ping` answers a fixed body, so a route test can tell the mount works.
    * `:echo` answers the exact request bytes the core preserved for this path
      (`conn.private[:raw_body]`) — what a webhook receiver needs to verify an
      HMAC — or an empty body if nothing was preserved.
    * `:tenant` answers the request's tenant id as the core's endpoint
      resolved it (`conn.assigns.current_org`), proving a plugin endpoint is
      tenant-scoped without the plugin asking.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(action) when action in [:ping, :echo, :tenant], do: action

  @impl Plug
  def call(conn, :ping), do: send_resp(conn, 200, "pong")
  def call(conn, :echo), do: send_resp(conn, 200, conn.private[:raw_body] || "")

  def call(conn, :tenant) do
    case conn.assigns[:current_org] do
      %{id: id} -> send_resp(conn, 200, to_string(id))
      _none -> send_resp(conn, 200, "")
    end
  end
end
