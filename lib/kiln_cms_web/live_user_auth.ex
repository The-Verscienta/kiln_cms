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

  # Requires a signed-in user with the :editor or :admin role (content authors).
  # Mirrors the RBAC content policies so non-editors can't reach authoring UIs.
  def on_mount(:live_editor_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{role: role} when role in [:editor, :admin] ->
        {:cont, socket}

      %{} ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           gettext("You need editor access to view that page.")
         )
         |> Phoenix.LiveView.redirect(to: ~p"/")}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  # Requires a signed-in user with the :admin role (admin-only authoring UIs:
  # webhooks, trash). Router-level guard mirroring the per-LiveView mount checks
  # and the Ash policies, so non-admins can't even mount the route.
  def on_mount(:live_admin_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{role: :admin} ->
        {:cont, socket}

      %{} ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           gettext("You need admin access to view that page.")
         )
         |> Phoenix.LiveView.redirect(to: ~p"/")}

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
end
