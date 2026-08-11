defmodule KilnCMSWeb.SignInLive do
  @moduledoc """
  `AshAuthentication.Phoenix.SignInLive` with the client's address attached, so
  the browser sign-in is charged the per-IP `:auth` bucket (#715).

  ## Why the limit cannot live where the event does

  `docs/threat-model.md` lists `/sign-in` under `:auth`, and the router does put
  `KilnCMSWeb.Plugs.RateLimit, :auth` on `:browser_auth`. But AshAuthentication's
  `sign_in_tokens_enabled?` defaults to true, so
  `AshAuthentication.Phoenix.Components.Password.SignInForm` handles `"submit"`
  **inside the LiveView** and calls `AshPhoenix.Form.submit/2` there. The
  credentials never travel through a form POST, so they never pass a pipeline.

  Nor can a hook catch the event on the way past. That form is a LiveComponent
  targeting `@myself`, and `Phoenix.LiveView.Diff.mount_component/3` gives a
  component socket a *fresh* `%Phoenix.LiveView.Lifecycle{}` — so a
  `:handle_event` hook attached by the LiveView never runs for it. There is no
  seam between the click and the password check.

  What there is, is the form's `context`, which the component tree threads from
  this view's `@context` assign down into `Form.for_action/3` and so onto the
  `Ash.Query`. So the limit is charged where the per-**account** budget already
  is — in `KilnCMS.Accounts.Preparations.ThrottleSignIn`, on the action itself —
  and this view's whole job is to tell it whose attempt it is. One attempt, one
  charge, on the same `:auth` bucket and the same address the HTTP form would
  have been keyed on.

  ## The alternative, and why not it

  Setting `sign_in_tokens_enabled? false` on the password strategy would make
  the form POST through `:browser_auth` — the pipeline that already carries
  `Plugs.RateLimit, :auth` — and would cover the register form the same way, in
  one DSL line rather than this. It was weighed and rejected on what it costs
  the page, not on difficulty: the token exchange is what lets the sign-in form
  render its own errors in place, and turning it off replaces that with a
  POST-redirect-flash round trip on every wrong password, on the surface where
  wrong passwords are most common. It also changes how `remember_me` is carried
  (`SignInForm.get_auth_path_params/2` passes it as a query param on the token
  exchange), which is live work in #699.

  ## Why a wrapper rather than a copy

  `sign_in_route`'s `live_view:` option is the supported way to swap the view,
  and everything below `mount/3` — the component tree, the overrides, the
  templates — is the library's. Delegating `render/1` and `handle_params/3`
  rather than restating them means an upstream change to the sign-in page
  arrives with the dependency instead of being silently frozen here.

  It also picks up `use KilnCMSWeb, :live_view`, which the library's view cannot
  use, and with it `KilnCMSWeb.LiveRouteGuard` (#688) — so a url-less join to
  `/sign-in`, `/register` or `/reset` is now refused rather than mounting
  without its `live_session` hooks.

  ## Where the address comes from

  The socket's own handshake (`:peer_data` / `:x_headers`, declared on `/live` in
  the endpoint), resolved through `KilnCMSWeb.Plugs.ClientIp.resolve/2` so the
  trusted-proxy rule is the one rule the HTTP plug applies. Not from the session:
  that is signed at the *disconnected* render and replayable, so it would name
  whichever address fetched the page rather than the one submitting now.

  Only on a connected **root** mount — see `charge_here?/1`. The disconnected
  render is a plain HTTP request that already passed the `:auth` plug and has no
  submit to charge, so resolving an address for it would be work thrown away: a
  header scan and, behind a proxy, a CIDR parse per page load.

  When the address cannot be resolved the attempt is charged to
  `KilnCMSWeb.RateLimit`'s shared unknown-client bucket rather than exempted.
  The endpoint's `connect_info` makes that unreachable, so it would mean the
  transport was reconfigured — and the safe reading of "we do not know who this
  is" is not "so there is no limit".
  """
  use KilnCMSWeb, :live_view

  # `use KilnCMSWeb, :live_view` replaces `use AshAuthentication.Phoenix.Web,
  # :live_view`, and a module's `on_mount` list is compile-time — delegating
  # `mount/3` does not carry it over. This is the hook that list contained, and
  # it is load-bearing: the auth components report success by
  # `send(self(), {:put_flash, …})` (`Flash.put_flash!/3`), which nothing
  # receives without the `:handle_info` hook this attaches. Without it a
  # password-reset or magic-link request on these pages silently renders no
  # confirmation at all, and the LiveView logs "undefined handle_info" at debug.
  on_mount AshAuthentication.Phoenix.Utils.Flash

  # Titles `/sign-in`, `/register` and `/reset` from their `live_action`
  # (#559). They are one view in one live session, patched between, so the
  # hook retitles on `handle_params` as well as on mount.
  on_mount KilnCMSWeb.AuthPageTitle

  alias AshAuthentication.Phoenix.SignInLive, as: Upstream
  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMSWeb.Plugs.ClientIp
  alias KilnCMSWeb.RateLimit

  require Logger

  @impl true
  def mount(params, session, socket) do
    # A strict match on the two-tuple, deliberately. `mount/3` may legally
    # answer `{:ok, socket, opts}` and upstream marks this one `@doc false`, so
    # a release that started returning `temporary_assigns:` would break here —
    # but it would break at *compile* time, because Elixir's type checker knows
    # `Upstream.mount/3`'s return and rejects a clause for a shape it cannot
    # produce. Writing the tolerant `case` is therefore not an option, and the
    # strict match is the thing that makes the upgrade loud rather than a
    # `MatchError` on the production sign-in page.
    {:ok, socket} = Upstream.mount(params, session, socket)

    if charge_here?(socket) do
      {:ok, update(socket, :context, &Map.merge(&1, client_ip_context(socket)))}
    else
      {:ok, socket}
    end
  end

  # The one `handle_params/3` in the app that passes its `uri` on rather than
  # discarding it, because upstream's signature takes it. Upstream discards it
  # today — but "a dependency ignores this argument" is not a property we
  # control across upgrades, and the argument is a URL the client chose (#687).
  # `vouch_uri/2` keeps the path and re-roots it on the authority the server
  # vouched for at mount, so a `live_patch` naming another org's host cannot
  # hand AshAuthentication that host.
  @impl true
  def handle_params(params, uri, socket),
    do: Upstream.handle_params(params, KilnCMSWeb.LiveUserAuth.vouch_uri(socket, uri), socket)

  @impl true
  def render(assigns), do: Upstream.render(assigns)

  # A connected ROOT mount, which is the only socket that has a handshake to
  # read. `get_connect_info/2` raises `raise_root_and_mount_only!` when
  # `socket.private[:connect_info]` is absent, and a nested `live_render` child
  # has no `connect_info` of its own — upstream's moduledoc advertises rendering
  # this page that way, so the raise is reachable by a plugin panel or a custom
  # landing page. Degrading to "no address in context" there is right rather
  # than merely safe: a nested child's join was already charged by whatever
  # served its parent.
  defp charge_here?(socket), do: connected?(socket) and is_nil(socket.parent_pid)

  defp client_ip_context(socket) do
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

    peer_address =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    x_headers
    |> ClientIp.resolve(peer_address)
    |> warn_if_unresolved()
    |> RateLimit.client_key()
    |> ThrottleSignIn.client_ip_context()
  end

  # An unresolvable address shares one node-wide bucket, so this is the shape of
  # a total sign-in outage: `:auth` is 20/min, and if `connect_info` ever stops
  # carrying `:peer_data` the 21st attempt from *anyone* is refused. The
  # endpoint's declaration makes that unreachable today, which is exactly why it
  # would be an endpoint edit that broke it — so say so out loud rather than
  # leaving an operator to diagnose a silent, global refusal.
  defp warn_if_unresolved(nil) do
    Logger.warning("""
    A /live socket connected with no resolvable client address, so its sign-in \
    attempts share one node-wide rate-limit bucket with every other such socket \
    — which will refuse legitimate sign-ins once that bucket is spent. The \
    endpoint's `/live` `connect_info` must carry `:peer_data` and `:x_headers` \
    (see KilnCMSWeb.Endpoint).\
    """)

    nil
  end

  defp warn_if_unresolved(address), do: address
end
