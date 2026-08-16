defmodule KilnCMSWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.I18n

  require Logger

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {KilnCMSWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    socket = AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)

    # Ensure current_scope is always present for <Layouts.app> (Phoenix 1.8 scopes + Agents.md guideline).
    # Our auth uses custom role-based LiveUserAuth rather than full Phoenix scopes.
    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:cont, socket}
  end

  # Restore the UI locale from the session into the LiveView process. LiveViews
  # mount in their own process, so the request-time `SetLocale` plug doesn't
  # carry over — set the Gettext locale here (and expose it as an assign).
  def on_mount(:restore_locale, _params, session, socket) do
    locale = I18n.normalize(session["locale"])
    Gettext.put_locale(KilnCMSWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end

  # Resolve the request's organization from the socket host and expose it as
  # `:current_org` (epic #336) — the LiveView analogue of the `SetTenant` plug
  # (LiveViews mount in their own process, so the plug's assign doesn't carry
  # over). Editor LiveViews pass it as the `tenant:` on authoring writes, so
  # authoring on a site's subdomain stamps content with that org.
  #
  # Under `TENANT_STRICT_HOST` a host that resolves to no org is refused with the
  # same 404 the `SetTenant` plug answers with (#563). `Phoenix.LiveView.Channel`
  # turns a 4xx `Plug.Exception` raised during mount into a client reload rather
  # than a crash, so this costs no crash report per rejected connect.
  #
  # On a CONNECTED mount `host_uri` is not a host at all — it is rebuilt from
  # the client's join payload, only whose *path* the router matches, and
  # `check_origin` admits every subdomain of the base host. So a connected mount
  # resolves from the socket's OWN request URI instead (`connect_info[:uri]`,
  # declared on `/live` in the endpoint), the same source `GraphqlSocket`,
  # `BridgeSocket` and `CollabSocket` already use and the same `Host` header
  # `SetTenant` trusts over HTTP (#654). The client's claim is then judged
  # against it and a socket claiming a DIFFERENT org is refused.
  #
  # The comparison is by resolved ORG, not by host string, because the question
  # is which tenant the socket acts as. Two spellings of one org's host — a
  # proxy that rewrites `Host` upstream, an IPv6 literal that `URI.parse`
  # unbrackets, a custom domain — name the same tenant and must not be a
  # refusal; two orgs must be, however similar the names.
  #
  # Until this, a client signed in on one org's host could join naming
  # another's and take its `:current_org`; only the fail-closed per-org tier
  # check (`KilnCMS.Accounts.Scoping.effective_tier/2`) stood behind an assign
  # that editor LiveViews pass as the `tenant:` on writes. That tier check is
  # still the authorization boundary — this makes the assign mean what its
  # callers already assumed, it does not replace authorizing against it.
  def on_mount(:assign_current_org, _params, _session, socket) do
    # `request_org!` first: it is what judges the client's claim, and it reads
    # `socket.host_uri` to do so. Vouching before it would erase the very claim
    # `refuse_foreign_claim!/3` exists to catch.
    org = request_org!(socket)

    {:cont, socket |> assign(:current_org, org) |> vouch_host_uri()}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    socket =
      if socket.assigns[:current_user] do
        socket
      else
        assign(socket, :current_user, nil)
      end

    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:cont, socket}
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  # Requires a signed-in user whose EFFECTIVE tier on this org is editor or
  # admin (#419). Mirrors the RBAC content policies so non-editors can't
  # reach authoring UIs — including org-demoted global editors.
  #
  # Also assigns `:pwa`, which the root layout keys the web app manifest and
  # iOS meta tags off (#65). Setting it *here*, rather than as its own on_mount
  # entry on the authoring live_sessions, keeps the install prompt and the
  # service worker attached to the same condition that authorises the editor UI
  # in the first place — a page that fails this check never advertises the app.
  def on_mount(:live_editor_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{} ->
        if effective_tier(socket) in [:editor, :admin] do
          {:cont, assign(socket, :pwa, true)}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(
             :error,
             gettext("You need editor access to view that page.")
           )
           |> Phoenix.LiveView.redirect(to: ~p"/")}
        end

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  # Requires an EFFECTIVE :admin tier on this org (#419) — admin-only
  # authoring UIs (webhooks, trash, team). Router-level guard mirroring the
  # per-LiveView mount checks and the Ash policies.
  def on_mount(:live_admin_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{} ->
        if effective_tier(socket) == :admin do
          {:cont, assign(socket, :pwa, true)}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(
             :error,
             gettext("You need admin access to view that page.")
           )
           |> Phoenix.LiveView.redirect(to: ~p"/")}
        end

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    socket =
      if socket.assigns[:current_user] do
        socket
      else
        assign(socket, :current_user, nil)
      end

    socket = assign_new(socket, :current_scope, fn -> nil end)
    {:cont, socket}
  end

  @doc """
  Re-root `uri` on the socket's vouched authority, keeping its path and query.

  `handle_params/3`'s `uri` argument is whatever URL the client put in its
  `live_patch` payload. LiveView's own Route.live_link_info!/3 checks the
  view module and the `live_session` name before accepting it — and **not the
  host** — so a socket legitimately mounted on `orga.example.com` can patch to
  `https://orgb.example.com/same/path` and be handed the attacker's host.

  Every `handle_params/3` in this app spells the argument `_uri` and is guarded
  by a test that says so, which is the real defence. This is for the one place
  that must pass a URI on to code we do not own (`KilnCMSWeb.SignInLive` hands
  it to AshAuthentication): the path is the caller's to choose, the authority
  is not.

  Falls back to `uri` unchanged when the socket carries no vouched authority —
  a `live_render/3` child or a socket mounted without `:assign_current_org` has
  nothing better to offer, and mangling the URL would be worse than passing it.
  """
  @spec vouch_uri(Phoenix.LiveView.Socket.t(), String.t()) :: String.t()
  def vouch_uri(socket, uri) when is_binary(uri) do
    case socket.host_uri do
      %URI{host: host} = vouched when is_binary(host) and host != "" ->
        client = URI.parse(uri)

        %URI{vouched | path: client.path, query: client.query, fragment: client.fragment}
        |> URI.to_string()

      _not_vouched ->
        uri
    end
  end

  # Replace the client's claim with what the server can vouch for (#687).
  #
  # `refuse_foreign_claim!/3` above stops a socket ACTING as another tenant, but
  # that guarantee is about `:current_org` and stops at mount. `host_uri` itself
  # keeps living: `Phoenix.VerifiedRoutes.url/1` inside a LiveView reads it,
  # LiveView builds redirect and navigate URLs from it, and a `live_patch`
  # hands `handle_params/3` a URL the client chose outright. So the next feature
  # that builds an absolute URL — a canonical tag, an email link, an OAuth
  # `redirect_uri` — would take its host, scheme or port from client input, with
  # no test failing and no reviewer prompted to look.
  #
  # Note the CLAIM is refused only when it names a different *org*; two
  # spellings of one org's host are both accepted, and the client's scheme and
  # port are never judged at all. `http://` and `:1337` therefore survive a
  # legitimate join. Rewriting from the endpoint's own config is what makes
  # `url/1` inside a LiveView agree with `url/1` everywhere else in the app,
  # which is the property callers already assume it has.
  #
  # Three things are deliberately left alone:
  #
  #   * `:not_mounted_at_router` — the socket claimed no URL, so there is
  #     nothing to vouch, and `KilnCMSWeb.LiveRouteGuard` matches on that exact
  #     sentinel. Replacing it with a URI would silently disarm that guard.
  #   * A socket whose host we could not resolve — a `live_render/3` child or
  #     `live_isolated/3`, which is not host-scoped at all.
  #   * The host, on a disconnected mount: it came from the conn, which is the
  #     same `Host` header `SetTenant` trusts, not from a join payload.
  defp vouch_host_uri(socket) do
    with %URI{} <- socket.host_uri,
         host when is_binary(host) and host != "" <- vouched_host(socket) do
      %{socket | host_uri: %{KilnCMSWeb.Endpoint.struct_url() | host: host}}
    else
      _nothing_to_vouch -> socket
    end
  end

  # The host the server is willing to stand behind, by the same split
  # `request_org!/1` makes: the handshake's own request URI when connected, the
  # conn-derived one when not.
  defp vouched_host(socket) do
    if Phoenix.LiveView.connected?(socket) do
      case Phoenix.LiveView.get_connect_info(socket, :uri) do
        %URI{host: host} -> host
        _no_request_uri -> nil
      end
    else
      case socket.host_uri do
        %URI{host: host} -> host
        _not_host_scoped -> nil
      end
    end
  end

  # A DISCONNECTED mount is a plain HTTP request: `host_uri` was built from the
  # conn, and `KilnCMSWeb.Plugs.SetTenant` already resolved that same `Host`
  # header this same way. A socket with no host there is not a host-scoped
  # request at all (`live_render/3` children, `live_isolated/3`), and keeps the
  # lenient default rather than being refused for a host nobody claimed.
  defp request_org!(socket) do
    if Phoenix.LiveView.connected?(socket) do
      connected_org!(socket)
    else
      case socket.host_uri do
        %URI{host: host} when is_binary(host) and host != "" -> fetch_org!(host)
        _not_host_scoped -> KilnCMSWeb.Tenant.resolve_org(nil)
      end
    end
  end

  # A CONNECTED mount is resolved from the socket's own request URI and never
  # from the client's claim (#654).
  #
  # A missing `:uri` is refused rather than fallen back on. It cannot happen on
  # a live transport — the endpoint declares `connect_info: [:uri]` on both of
  # `/live`'s — so the only way to reach it is that declaration going missing,
  # which is exactly when quietly trusting the client again would be worst.
  defp connected_org!(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :uri) do
      %URI{host: host} when is_binary(host) and host != "" ->
        org = fetch_org!(host)
        refuse_foreign_claim!(socket, org, host)
        org

      _no_request_uri ->
        raise KilnCMSWeb.Tenant.UnknownHostError, host: nil
    end
  end

  # The claim is not what resolves the tenant, so this changes no assign — it
  # exists so that a client naming someone else's org is refused rather than
  # quietly served its own. A socket that claims nothing (`live_patch`-less
  # joins carry no URL, so `host_uri` is `:not_mounted_at_router`) has made no
  # claim to contradict.
  defp refuse_foreign_claim!(socket, %{id: org_id}, connected_host) do
    with %URI{host: claimed} when is_binary(claimed) and claimed != "" <- socket.host_uri,
         false <- match?({:ok, %{id: ^org_id}}, KilnCMSWeb.Tenant.fetch_org(claimed)) do
      # Debug, not warning, for the reason `SetTenant` gives: this is
      # client-triggerable, so one log line per refusal is an unbounded write.
      # An operator debugging a socket that will not connect drops the level and
      # sees both hosts.
      Logger.debug(fn ->
        "LiveUserAuth: socket on #{inspect(connected_host)} claimed #{inspect(claimed)}"
      end)

      raise KilnCMSWeb.Tenant.HostMismatchError, claimed: claimed, connected: connected_host
    else
      _ -> :ok
    end
  end

  # Both `request_org!/1`'s disconnected path and `connected_org!/1` funnel
  # their unresolvable-host refusal through here, so this is the one place to
  # alert (#678) — never `Tenant.fetch_org/1` itself (shared with every
  # caller that resolves leniently) and never `refuse_foreign_claim!/3` below
  # (that refusal is driven by the client's own claim, not by a host that
  # failed to resolve, so counting it would answer a different question).
  defp fetch_org!(host) do
    case KilnCMSWeb.Tenant.fetch_org(host) do
      {:ok, org} ->
        org

      :error ->
        KilnCMSWeb.TenantRefusalAlert.notify(:live, host)
        raise KilnCMSWeb.Tenant.UnknownHostError, host: host

      # A lookup that could not run, not a host nobody serves — so it raises the
      # 503 twin and does *not* alert: the refusal alert counts unserved hosts
      # and names `TENANT_STRICT_HOST` as the cause, which is the wrong
      # diagnosis for a database that is down.
      :unavailable ->
        raise KilnCMSWeb.Tenant.UnavailableError, host: host
    end
  end

  @doc """
  The current user's effective capability tier on the socket's org (#419 —
  per-org tiers). Requires `:assign_current_org` to have run (it precedes the
  tier gates in the router's live sessions).
  """
  def effective_tier(socket_or_conn) do
    KilnCMS.Accounts.Scoping.effective_tier(
      socket_or_conn.assigns[:current_user],
      KilnCMSWeb.Tenant.current_org_id(socket_or_conn)
    )
  end

  @doc """
  Whether the current user is a **platform** admin (global `User.role`), the
  gate for consoles backed by instance-wide/global resources — API keys,
  team+membership administration, mail settings (#419). These are NOT per-org
  tiers: a per-org membership admin must not reach them (their resource
  policies stay on the global role, so `effective_tier` would admit them to a
  page every action then forbids).
  """
  def platform_admin?(socket_or_conn) do
    case socket_or_conn.assigns[:current_user] do
      %{role: :admin} -> true
      _ -> false
    end
  end
end
