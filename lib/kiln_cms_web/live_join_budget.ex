defmodule KilnCMSWeb.LiveJoinBudget do
  @moduledoc """
  A per-address budget on `/live` **root joins** (#1183) — the residual of
  #678, which metered only the joins a tenant refused.

  A connected LiveView root mount costs a session verify, the route's
  `on_mount` hooks, a `mount/3` (typically several database reads) and a
  render. Until this hook, none of that was counted: `docs/threat-model.md`
  item 10 records that "joins are uncounted, so a caller replaying a scraped
  session token pays nothing per attempt". #715 bounded the one join-borne
  *confidentiality* concern (the sign-in submit charges `:auth` on the action);
  what was left is volume — availability, not confidentiality — and this is
  the narrow first cut the issue asked for: `/live` root mounts, not the
  `/ws/*` families, and not per-event.

  ## Where it runs, and why there

  Declared by `KilnCMSWeb.live_view/0`, next to `KilnCMSWeb.LiveRouteGuard`
  and before it, so it is attached to every LiveView **module** rather than to
  a `live_session` — a url-less join skips the router's hooks entirely (#688),
  and a flood of those is exactly the traffic a budget has to see. Ordered
  first so a refused-as-unrouted join is still charged.

  Only a **connected root** mount is charged (`connected?/1` and no
  `parent_pid`), for the reason `KilnCMSWeb.SignInLive.charge_here?/1` gives:
  the dead render is an HTTP request that already went through the router, a
  nested `live_render` child has no handshake of its own and its parent's join
  was already charged, and only a root socket carries the `connect_info` this
  reads the address from. A `live_patch`/`live_navigate` inside one
  `live_session` does not remount the root, so an editor moving around the
  console costs one join per page *load*, not per click.

  ## The address, and the bucket it charges

  Resolved exactly as `SignInLive` resolves it — `:x_headers` through
  `KilnCMSWeb.Plugs.ClientIp.resolve/2` with `:peer_data` as the fallback —
  and keyed through `KilnCMSWeb.RateLimit.client_key/1`, so the same client
  spells the same key here, on the sign-in submit and at the HTTP plug. An
  address the handshake cannot resolve shares `RateLimit`'s one node-wide
  unknown-client bucket rather than being exempted (the safe reading of "we
  do not know who this is"); the endpoint declares `:peer_data` on `/live`,
  so today that only happens if that declaration is edited.

  The bucket is `:live_join` (`KilnCMSWeb.RateLimit`), sized as a flood
  ceiling and not a usage cap: an office NAT behind which twenty editors each
  reload a console page a few times a minute is nowhere near it, and a
  scripted replay of one scraped `data-phx-session` token is over it in
  seconds. `config :kiln_cms, KilnCMSWeb.RateLimit, limits: %{live_join: …}`
  overrides it like every other bucket; the test env raises it, and the suite
  that pins this hook lowers it back for its own tests.

  ## What a refusal looks like

  `TooManyJoinsError`, `plug_status: 429`. `Phoenix.LiveView.Channel` turns a
  4xx raised during mount into `{:error, %{reason: "reload", status: 429}}`
  and stops the channel process — no `mount/3`, no render, no LiveView
  process left behind. The honest client (`phoenix_live_view.js`) responds by
  reloading the page with jittered backoff and gives up after a bounded number
  of attempts, so an editor who somehow trips it sees the dead render and a
  reconnect a few seconds later rather than a spinner. A scripted client gets
  a closed socket per attempt, which is the point. Same mechanism
  `LiveRouteGuard` and `KilnCMSWeb.Tenant`'s errors rely on.

  Logged at `:debug`, not `:warning`, for the reason `LiveRouteGuard` gives:
  client-triggerable, so a line per refusal is an unbounded write.

  ## What it does not cover

  The `/ws/gql`, `/ws/bridge` and `/ws/collab` sockets (their own `connect/3`
  callbacks are the analogous place; not in scope here — see the issue), and
  events on an established socket. `KilnCMSWeb.SocketEventBudget` (#1305) now
  counts the latter for `/ws/collab`, per connection rather than per address;
  `/live` events and the rest remain in threat-model item 10.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  alias KilnCMSWeb.Plugs.ClientIp
  alias KilnCMSWeb.RateLimit

  require Logger

  @bucket :live_join

  defmodule TooManyJoinsError do
    @moduledoc """
    Raised when an address has spent its `/live` root-join budget (#1183).

    `plug_status: 429` — the channel turns it into a `reload` reply and stops,
    which is what a client that is not flooding does not need and a client
    that is cannot avoid paying for. Carries `retry_after_ms` for an operator
    reading the debug log; the channel reply itself carries only the status.
    """
    defexception [:retry_after_ms, :message, plug_status: 429]

    @impl true
    def exception(opts) when is_list(opts) do
      retry_after_ms = Keyword.get(opts, :retry_after_ms)

      %__MODULE__{
        retry_after_ms: retry_after_ms,
        message: "LiveView root join refused: address over its join budget"
      }
    end

    def exception(message) when is_binary(message), do: %__MODULE__{message: message}
  end

  @doc "The `KilnCMSWeb.RateLimit` bucket this hook charges."
  @spec bucket() :: atom()
  def bucket, do: @bucket

  @doc """
  Charges a connected root mount against the client's `:live_join` bucket and
  refuses it when spent. Declared by `KilnCMSWeb.live_view/0`.
  """
  def on_mount(:default, _params, _session, socket) do
    if charge_here?(socket), do: charge!(socket)
    {:cont, socket}
  end

  defp charge!(socket) do
    case RateLimit.check(@bucket, client_key(socket)) do
      :allow ->
        :ok

      {:deny, retry_after_ms} ->
        Logger.debug(fn ->
          "LiveJoinBudget: refused root join for #{inspect(socket.view)} " <>
            "(retry in #{retry_after_ms}ms)"
        end)

        raise TooManyJoinsError, retry_after_ms: retry_after_ms
    end
  end

  # A connected ROOT mount — see the moduledoc.
  defp charge_here?(socket), do: connected?(socket) and is_nil(socket.parent_pid)

  defp client_key(socket) do
    x_headers = get_connect_info(socket, :x_headers) || []

    peer_address =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    x_headers
    |> ClientIp.resolve(peer_address)
    |> RateLimit.client_key()
  end
end
