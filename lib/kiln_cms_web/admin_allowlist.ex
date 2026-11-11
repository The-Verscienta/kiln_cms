defmodule KilnCMSWeb.AdminAllowlist do
  @moduledoc """
  The socket half of a site's admin allowlist (#2248), and what both halves
  share. The HTTP half is `KilnCMSWeb.Plugs.AdminAllowlist`; the list and the
  matching are `KilnCMS.Security.AdminAllowlist`.

  ## Which LiveViews

  The ones whose routes the HTTP gate covers: every `live_session` in a scope
  behind the router's `:admin_allowlist` pipeline, each of which declares
  `{KilnCMSWeb.AdminAllowlist, :gated}`, and every one behind
  `:sign_in_allowlist`, which declares `{KilnCMSWeb.AdminAllowlist,
  :gated_sign_in}` (`gated_live_sessions/0`, `live_session_surface/1`;
  `admin_allowlist_routes_test.exs` pins that they agree, route by route). The
  second kind is judged on the `:sign_in` surface, which a site can open while
  its console stays behind the list (#2493). The sign-in page checks the password over its socket
  (`KilnCMSWeb.SignInLive`), so without this an outsider could test passwords
  from anywhere; the console pages need it because a socket outlives the HTTP
  request that opened it.

  The hook is declared twice, and runs once:

    * on every LiveView **module** (`KilnCMSWeb.live_view/0`, after the join
      budget, so a refused join is still charged), which a url-less join
      cannot skip. It acts only for a gated `live_session`
      (`socket.private[:live_session_name]`, signed; see
      `KilnCMSWeb.LiveRouteGuard`);
    * as `{KilnCMSWeb.AdminAllowlist, :gated}` (or `:gated_sign_in`) in each
      gated `live_session`, for a
      plugin LiveView that uses `Phoenix.LiveView` directly and so carries no
      module hook. It stands aside for a view that has one.

  Only a connected **root** mount is checked: the dead render is an HTTP
  request the plug already judged, and a child's gate is its parent's.

  ## Which address

  Two, and both must be on the list when the list is on:

    * the address the HTTP gate admitted, **stamped** into the page's signed
      LiveView session when the gated page was rendered (`stamp_conn/2`), with
      the site it was rendered for. A socket on Fly.io or DigitalOcean App
      Platform never sees the client's address (`Fly-Client-IP` and
      `do-connecting-ip` are not `x-` headers), and neither does one behind a
      proxy that sets only `Forwarded:`; the stamp is the HTTP gate's own
      answer. A session rendered for another site, or with no stamp, admits
      nothing while a list is on;
    * the socket's own address, whenever the socket can see the client
      (`KilnCMSWeb.Plugs.ClientIp.socket_client/2`).

  Where the socket cannot see the client, the stamp is all there is, so it
  vouches only while it is fresh (`stamp_max_age_seconds/0`, five minutes).
  After that a reconnect or a live navigation reloads the page over HTTP,
  which the gate judges and re-stamps. A session token carried to another
  network, or scraped from a sign-in page, stops admitting a join within that
  window rather than for the token's two weeks.

  A refused join raises `RefusedError` (`plug_status: 403`): the channel answers
  with a `reload`, and the reload's HTTP request meets the gate's 403 page.

  It fails closed: a host whose site cannot be resolved, or a list that cannot
  be read, refuses the join.

  ## Pages already open

  An admitted page keeps its addresses and surface, and listens on the site's
  topic. A save broadcasts the new setting
  (`KilnCMS.CMS.Changes.AdminAllowlistChanged`), and a page whose addresses it
  no longer admits for the page's surface (so a sign-in page also leaves when
  "Also restrict sign-in" is turned back on) is sent to `/editor` by a full page
  load, which the HTTP gate refuses. A dropped connection re-joins through the
  hook, and a `live_session` cannot be crossed without an HTTP request, so a
  page cannot move outside what the gates saw.

  ## `/ws/collab`

  `check_connect/2` from the socket's `connect`. A raw socket has no LiveView
  session and so no stamp: it is judged on the socket's own address, and where
  the socket cannot see the client (Fly.io, App Platform) a connect is refused
  while a list is on. `KilnCMSWeb.CollabChannel` judges the same address again
  at every re-authorization, so a list change closes an open room within
  `KilnCMSWeb.SocketReauth`'s window.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  alias KilnCMS.Security.AdminAllowlist
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.Plugs.ClientIp

  defmodule RefusedError do
    @moduledoc """
    Raised when a gated `/live` root join comes from outside the site's admin
    allowlist, or the list cannot be read (#2248). `plug_status: 403` is what
    the channel turns into a `reload`; the reload's HTTP request gets the
    gate's page (or its 503).
    """
    defexception message: "LiveView root join refused by the admin allowlist", plug_status: 403
  end

  @private :kiln_admin_allowlist
  @stamp_key :kiln_admin_allowlist
  @session_key "kiln_admin_allowlist"
  @gated_key {__MODULE__, :gated_live_session_surfaces}

  # How long a stamp vouches for a join when the socket cannot see the client.
  # A dead render's own join comes within a second; reconnects after a blip and
  # live navigation reuse the page's token. Past this, the next join reloads,
  # and the reload's HTTP request re-stamps the page if its address is still
  # listed: one extra page load every five minutes for someone navigating, while
  # a session token carried elsewhere (LiveView accepts one for two weeks), or
  # scraped from a sign-in page, stops vouching. Longer than the list's cache
  # TTL so a person moving around the console is not reloaded every minute.
  @stamp_max_age_seconds 300

  # --- the stamp ----------------------------------------------------------------

  @doc """
  Records the address the HTTP gate admitted, and the site it admitted it for,
  in the request's Ash context — which `ash_authentication_live_session` and the
  AshAuthentication route macros sign into the LiveView session as `"context"`.
  `live_session/1` signs it for a plain `live_session`. Called by the plug on
  every request it lets through.
  """
  @spec stamp_conn(Plug.Conn.t(), Ash.UUID.t()) :: Plug.Conn.t()
  def stamp_conn(conn, org_id) do
    context = Ash.PlugHelpers.get_context(conn) || %{}
    stamp = %{org_id: org_id, ip: conn.remote_ip, at: System.system_time(:second)}
    Ash.PlugHelpers.set_context(conn, Map.put(context, @stamp_key, stamp))
  end

  @doc """
  The `session:` of a plain gated `live_session` (`:first_run`,
  `:invitation`): the stamp the plug left on the conn.
  """
  @spec live_session(Plug.Conn.t()) :: map()
  def live_session(conn) do
    case Ash.PlugHelpers.get_context(conn) do
      %{@stamp_key => %{} = stamp} -> %{@session_key => stamp}
      _no_stamp -> %{}
    end
  end

  defp stamp(session) do
    case session do
      %{@session_key => %{org_id: _, ip: _} = stamp} -> stamp
      %{"context" => %{@stamp_key => %{org_id: _, ip: _} = stamp}} -> stamp
      _none -> nil
    end
  end

  @doc "How long, in seconds, a stamp alone may admit a join (see \"Which address\")."
  @spec stamp_max_age_seconds() :: pos_integer()
  def stamp_max_age_seconds, do: @stamp_max_age_seconds

  @doc """
  The stamped address of a page, for its own site, from its LiveView
  `session`; `nil` when there is none or it was stamped for another site.
  """
  @spec stamped_ip(map(), Ash.UUID.t() | nil) :: :inet.ip_address() | nil
  def stamped_ip(session, org_id) do
    case stamp(session) do
      %{org_id: ^org_id, ip: ip} when is_binary(org_id) -> ip
      _none_or_other_site -> nil
    end
  end

  # --- which live sessions ------------------------------------------------------

  @doc """
  The `live_session`s that declare `{KilnCMSWeb.AdminAllowlist, :gated}` or
  `:gated_sign_in`, read from the router once per node. They are the ones
  whose routes sit behind the `:admin_allowlist` or `:sign_in_allowlist`
  pipeline, which `admin_allowlist_routes_test.exs` pins route by route, so the
  join is gated wherever the HTTP request is.
  """
  @spec gated_live_sessions() :: [atom()]
  def gated_live_sessions, do: gated_surfaces() |> Map.keys() |> Enum.sort()

  @doc """
  The surface a gated `live_session` is judged on: `:console` for one that
  declares `:gated`, `:sign_in` for `:gated_sign_in`, `nil` for one that is
  not gated.
  """
  @spec live_session_surface(atom() | nil) :: AdminAllowlist.surface() | nil
  def live_session_surface(name), do: Map.get(gated_surfaces(), name)

  defp gated_surfaces do
    # Keyed on the router's build, so a recompiled router (dev) is read again.
    key = {@gated_key, KilnCMSWeb.Router.module_info(:md5)}

    case :persistent_term.get(key, nil) do
      nil ->
        surfaces = KilnCMSWeb.Router.__routes__() |> Enum.flat_map(&gated_session/1) |> Map.new()
        :persistent_term.put(key, surfaces)
        surfaces

      surfaces ->
        surfaces
    end
  end

  defp gated_session(route) do
    case get_in(route, [Access.key(:metadata, %{}), :phoenix_live_view]) do
      {_view, _action, _opts, %{name: name, extra: %{on_mount: hooks}}} ->
        Enum.flat_map(hooks, fn
          %{id: {__MODULE__, :gated}} -> [{name, :console}]
          %{id: {__MODULE__, :gated_sign_in}} -> [{name, :sign_in}]
          _other -> []
        end)

      _not_live ->
        []
    end
  end

  # --- /live --------------------------------------------------------------------

  @doc false
  def on_mount(:default, _params, session, socket) do
    surface = live_session_surface(socket.private[:live_session_name])

    if root_join?(socket) and not is_nil(surface),
      do: admit(socket, session, surface),
      else: {:cont, socket}
  end

  # The live_session's copy: only for a view with no module hook of its own.
  def on_mount(:gated, _params, session, socket), do: gated(socket, session, :console)
  def on_mount(:gated_sign_in, _params, session, socket), do: gated(socket, session, :sign_in)

  defp gated(socket, session, surface) do
    if root_join?(socket) and not module_hook?(socket.view),
      do: admit(socket, session, surface),
      else: {:cont, socket}
  end

  defp root_join?(socket),
    do: connected?(socket) and is_nil(socket.parent_pid) and is_nil(socket.private[@private])

  defp module_hook?(view) do
    function_exported?(view, :__live__, 0) and
      Enum.any?(view.__live__().lifecycle.mount, &match?(%{id: {__MODULE__, _}}, &1))
  end

  defp admit(socket, session, surface) do
    case KilnCMSWeb.Tenant.fetch_org_from_connect_info(%{uri: get_connect_info(socket, :uri)}) do
      {:ok, org} ->
        judge(socket, session, org.id, surface)

      # Unlike the block list, a host that names no site, or a site that cannot
      # be looked up, refuses: this is the console and sign-in.
      _error_or_unavailable ->
        count_refusal(:live, :unavailable)
        raise RefusedError
    end
  end

  defp judge(socket, session, org_id, surface) do
    socket_ip = ClientIp.socket_client_from(socket)
    ips = [vouching_ip(session, org_id, socket_ip) | List.wrap(socket_ip)]

    case AdminAllowlist.verdict(AdminAllowlist.policy(org_id, surface), ips) do
      :allowed ->
        {:cont, watch(socket, org_id, ips, surface)}

      reason ->
        count_refusal(:live, reason)

        if reason == :not_listed do
          request = Recorder.request_context(socket)
          ip = socket_ip || stamped_ip(session, org_id)
          record_refusal(org_id, ip, %{request | ip: format_ip(ip)}, :live)
        end

        raise RefusedError
    end
  end

  # The stamped address, when it may vouch for this join: always when the socket
  # saw the client too (both are checked), and only while it is fresh when the
  # stamp is all there is. A stamp from before the age limit was introduced
  # carries no time and is stale.
  defp vouching_ip(session, org_id, nil = _socket_ip) do
    case stamp(session) do
      %{org_id: ^org_id, ip: ip, at: at} when is_integer(at) ->
        if System.system_time(:second) - at <= @stamp_max_age_seconds, do: ip

      _none_stale_or_other_site ->
        nil
    end
  end

  defp vouching_ip(session, org_id, _socket_ip), do: stamped_ip(session, org_id)

  defp watch(socket, org_id, ips, surface) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, AdminAllowlist.topic(org_id))

    socket
    |> Phoenix.LiveView.put_private(@private, %{org_id: org_id, ips: ips, surface: surface})
    |> Phoenix.LiveView.attach_hook(:admin_allowlist, :handle_info, &handle_info/2)
  end

  defp handle_info({:admin_allowlist_changed, stored}, %{private: %{@private => state}} = socket) do
    policy =
      if AdminAllowlist.disabled?(),
        do: :off,
        else: AdminAllowlist.for_surface(stored, Map.get(state, :surface, :console))

    case AdminAllowlist.verdict(policy, state.ips) do
      :allowed ->
        {:halt, socket}

      reason ->
        count_refusal(:live, reason)
        {:halt, Phoenix.LiveView.redirect(socket, to: "/editor")}
    end
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # --- /ws/collab ---------------------------------------------------------------

  @doc """
  `{:ok, address}` to let a raw socket's connect go on (the address the
  socket's later re-checks use), `:error` to refuse it. See "`/ws/collab`".
  """
  @spec check_connect(atom(), map()) :: {:ok, :inet.ip_address() | nil} | :error
  def check_connect(surface, connect_info) when is_map(connect_info) do
    peer =
      case Map.get(connect_info, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    ip = ClientIp.socket_client(Map.get(connect_info, :x_headers) || [], peer)

    case KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info) do
      {:ok, org} ->
        judge_connect(surface, connect_info, org.id, ip)

      _error_or_unavailable ->
        count_refusal(surface, :unavailable)
        :error
    end
  end

  defp judge_connect(surface, connect_info, org_id, ip) do
    case AdminAllowlist.check(org_id, ip) do
      :allowed ->
        {:ok, ip}

      reason ->
        count_refusal(surface, reason)

        if reason == :not_listed,
          do: record_refusal(org_id, ip, Recorder.request_context(connect_info), surface)

        :error
    end
  end

  # --- shared -------------------------------------------------------------------

  @doc """
  Emits `kiln_cms.admin_allowlist.refused.count`, tagged with the surface and
  the reason (`not_listed` or `unavailable`). No address.
  """
  @spec count_refusal(atom(), atom()) :: :ok
  def count_refusal(surface, reason) do
    :telemetry.execute([:kiln_cms, :admin_allowlist, :refused], %{count: 1}, %{
      surface: surface,
      reason: reason
    })
  end

  @doc """
  Records `admin_access_refused` in the site's security log, sampled per site
  and address (an IPv6 address per `/64`, which one client can rotate through):
  anyone outside can cause one. No actor: the gate runs before anyone is known.
  """
  @spec record_refusal(Ash.UUID.t(), :inet.ip_address() | nil, map(), atom()) :: :ok | :skipped
  def record_refusal(org_id, ip, request, surface) do
    Recorder.record_sampled(:admin_access_refused,
      tenant: org_id,
      request: request,
      sample_key: Cidr.client_range(ip),
      metadata: %{"surface" => Atom.to_string(surface)}
    )
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
