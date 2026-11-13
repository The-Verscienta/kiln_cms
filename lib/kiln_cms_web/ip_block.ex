defmodule KilnCMSWeb.IpBlock do
  @moduledoc """
  The socket half of the operator's IP block list (#2242). The HTTP half is
  `KilnCMSWeb.Plugs.IpBlock`; the matching is `KilnCMS.Security.IpBlocklist`.

  A socket bypasses the endpoint's plugs, so each one checks for itself, with the
  same two inputs the join budgets use: the client address from
  `KilnCMSWeb.Plugs.ClientIp.resolve/2` over `:x_headers` and `:peer_data`, and
  the organization from the connecting host (`KilnCMSWeb.Tenant`, the resolution
  `KilnCMSWeb.LiveUserAuth` uses).

    * `/live` — `on_mount/4`, declared by `KilnCMSWeb.live_view/0` ahead of
      `KilnCMSWeb.LiveJoinBudget`, so it is on every LiveView module (the router's
      hooks are skipped by a url-less join, #688) and covers the websocket and
      longpoll transports alike, both being a channel join. Only a connected
      **root** mount is checked: the dead render is an HTTP request the plug
      already saw. A blocked join raises `BlockedError`, `plug_status: 403`,
      which the channel turns into a `reload` reply: no mount, no process, and the
      reload's HTTP request meets the plug's bare 403.
    * `/ws/gql`, `/ws/collab`, `/ws/bridge` — `check_connect/2` from the socket's
      `connect`, first of all: `:error` refuses the handshake.

  Everything fails open: a host that names no organization, a connect with no
  address, an unreadable rule list. Those are refused (or not) by the code that
  already owns them. Nothing here logs an address. A refusal is noted for the
  site's `blocked_ip` alert with its surface (`KilnCMS.Security.BlockedIpAlert`).
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  alias KilnCMSWeb.Plugs.ClientIp

  defmodule BlockedError do
    @moduledoc "Raised when a `/live` root join comes from a blocked address (#2242)."
    defexception message: "LiveView root join refused", plug_status: 403
  end

  @doc "Emits the refusal counter (`kiln_cms.ip_block.refused.count`). No address."
  @spec count_refusal(atom()) :: :ok
  def count_refusal(surface),
    do: :telemetry.execute([:kiln_cms, :ip_block, :refused], %{count: 1}, %{surface: surface})

  @doc """
  `:ok` to let a socket connect go on, `:error` to refuse it.

  `connect_info` is the map a `Phoenix.Socket` receives (a raw transport's is one
  level down, under `:connect_info`, and the caller unwraps it).
  """
  @spec check_connect(atom(), map()) :: :ok | :error
  def check_connect(surface, connect_info) when is_map(connect_info) do
    case blocked_connect(connect_info) do
      {:blocked, org_id, ip, rule} ->
        count_refusal(surface)

        KilnCMS.Security.BlockedIpAlert.note(org_id, ip, rule, surface, fn ->
          KilnCMS.Security.Recorder.request_context(connect_info)
        end)

        :error

      :ok ->
        :ok
    end
  end

  defp blocked_connect(connect_info) do
    peer =
      case Map.get(connect_info, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    ip = ClientIp.resolve(Map.get(connect_info, :x_headers) || [], peer)

    with false <- is_nil(ip),
         {:ok, org} <- KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info),
         {:blocked, rule} <- KilnCMS.Security.IpBlocklist.match(org, ip) do
      {:blocked, org.id, ip, rule}
    else
      _no_address_org_or_rule -> :ok
    end
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and is_nil(socket.parent_pid) do
      connect_info = %{
        uri: get_connect_info(socket, :uri),
        x_headers: get_connect_info(socket, :x_headers),
        peer_data: get_connect_info(socket, :peer_data),
        user_agent: get_connect_info(socket, :user_agent)
      }

      if check_connect(:live, connect_info) == :error, do: raise(BlockedError)
    end

    {:cont, socket}
  end
end
