defmodule KilnCMSWeb.SocketJoinBudget do
  @moduledoc """
  A per-address budget on `/ws/gql`, `/ws/bridge` and `/ws/collab` connects —
  the `/ws/*` half of `docs/threat-model.md` item 10's remaining gap, left
  open on purpose when #1183 narrowed the same item to `/live` root joins
  first (`KilnCMSWeb.LiveJoinBudget`'s own moduledoc names this half as out
  of scope there).

  Unlike `/live`, which is one route family behind one `Phoenix.LiveView.Socket`,
  these are three independent transports with three independent `connect/2,3`
  callbacks — a `Phoenix.Socket` each for `/ws/gql` and `/ws/collab`, a raw
  `Phoenix.Socket.Transport` for `/ws/bridge`. This module is the one place
  that resolves a connect's client address and checks it against a budget;
  each socket's own `connect` callback calls `charge/2` with its own bucket,
  first, ahead of tenant/auth resolution — the same ordering
  `KilnCMSWeb.LiveJoinBudget` uses and for the same reason: a connect this
  deployment will refuse anyway (an unresolvable host, a bad token) still
  cost a process spin-up and a handshake, so it still has to count.

  ## Three buckets, not one

  `KilnCMSWeb.RateLimit` gets three new buckets — `:gql_join`, `:bridge_join`,
  `:collab_join` — rather than one shared bucket, for the same reason
  `:live_join` is its own bucket rather than a share of `:gql`: `/ws/gql` is
  the one of the three that is anonymous by default, so a flood against it
  must not spend a budget an editor's `/ws/collab` session — which needs a
  server-minted token and so is reachable only after signing in — then pays
  for, if both happen to connect from the same office NAT.

  ## The address, and what a refusal looks like

  Resolved exactly as `LiveJoinBudget` resolves it: `:x_headers` through
  `KilnCMSWeb.Plugs.ClientIp.resolve/2` with `:peer_data` as the fallback, keyed
  through `KilnCMSWeb.RateLimit.client_key/1` — the same spelling the `/live`
  socket and the HTTP plug use, so a client behind one address shares one
  identity across every surface that charges it. A connect whose `connect_info`
  carries neither (a raw transport whose declaration was edited, or a bare map
  a test passes) shares `RateLimit`'s one node-wide unknown-client bucket.

  A raw `Phoenix.Socket.Transport`'s `connect/1` and a `Phoenix.Socket`'s
  `connect/2,3` both refuse a connection the same way: returning `:error`
  (or falling out of a `with` that does). There is no 4xx-during-mount shape
  to raise here the way `LiveJoinBudget` does for a LiveView join — a refused
  socket connect simply never completes the handshake, and the client's own
  reconnect logic (Absinthe's socket, `bridge.js`, the collab room's client)
  backs off and retries.
  """

  require Logger

  alias KilnCMSWeb.Plugs.ClientIp
  alias KilnCMSWeb.RateLimit

  @doc """
  Charges a socket connect attempt against `bucket`, keyed on the client
  address resolved from `connect_info`.

  Returns `:ok` to let the connect continue, `:error` to refuse it. Call this
  first, ahead of tenant/auth resolution — see the moduledoc.
  """
  @spec charge(atom(), map()) :: :ok | :error
  def charge(bucket, connect_info) when is_atom(bucket) and is_map(connect_info) do
    case RateLimit.check(bucket, client_key(connect_info)) do
      :allow ->
        :ok

      {:deny, retry_after_ms} ->
        Logger.debug(fn ->
          "SocketJoinBudget: refused #{bucket} connect (retry in #{retry_after_ms}ms)"
        end)

        :error
    end
  end

  defp client_key(connect_info) do
    x_headers = Map.get(connect_info, :x_headers) || []

    peer_address =
      case Map.get(connect_info, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    x_headers
    |> ClientIp.resolve(peer_address)
    |> RateLimit.client_key()
  end
end
