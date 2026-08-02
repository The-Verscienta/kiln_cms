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
    {:cont, assign(socket, :current_org, request_org!(socket))}
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

  defp fetch_org!(host) do
    case KilnCMSWeb.Tenant.fetch_org(host) do
      {:ok, org} -> org
      :error -> raise KilnCMSWeb.Tenant.UnknownHostError, host: host
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
