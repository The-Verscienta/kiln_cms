defmodule KilnCMSWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.I18n

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
  def on_mount(:assign_current_org, _params, _session, socket) do
    host =
      case socket.host_uri do
        %URI{host: h} -> h
        _ -> nil
      end

    {:cont, assign(socket, :current_org, KilnCMSWeb.Tenant.resolve_org(host))}
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
  def on_mount(:live_editor_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{} ->
        if effective_tier(socket) in [:editor, :admin] do
          {:cont, socket}
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
          {:cont, socket}
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
