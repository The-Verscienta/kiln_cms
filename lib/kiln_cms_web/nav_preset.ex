defmodule KilnCMSWeb.NavPreset do
  @moduledoc """
  The `"set_nav_preset"` event — the console sidebar's "Show all tools" /
  "Show essentials" switch, and the same choice on Your settings.

  The switch is drawn by `Layouts.console/1`, which every console LiveView
  renders, so the event reaches whichever LiveView is on screen. Rather than
  each of them handling it, `KilnCMSWeb.LiveUserAuth` attaches this as a
  `handle_event` hook on every signed-in mount: it saves the preset through the
  self-only `:set_nav_preset` action and assigns the result onto
  `current_user`, which re-renders the layout's sidebar in place — no reload,
  no navigation.

  Only `nav_preset` is copied onto the socket's user, never the returned
  record: the socket actor carries a folded temporary role
  (`KilnCMS.Accounts.Preparations.FoldRoleGrant`) that an update's return value
  does not, and swapping the struct would quietly demote a live grant.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias KilnCMS.Accounts

  @presets %{"essentials" => :essentials, "everything" => :everything}

  @doc "Attach the hook to a signed-in socket."
  def attach(socket),
    do: Phoenix.LiveView.attach_hook(socket, :nav_preset, :handle_event, &handle_event/3)

  @doc false
  def handle_event("set_nav_preset", %{"preset" => preset}, socket)
      when is_map_key(@presets, preset) do
    %{current_user: user} = socket.assigns

    case Accounts.set_nav_preset(user, Map.fetch!(@presets, preset), actor: user) do
      {:ok, updated} ->
        {:halt, assign(socket, :current_user, %{user | nav_preset: updated.nav_preset})}

      {:error, _error} ->
        {:halt,
         Phoenix.LiveView.put_flash(socket, :error, gettext("The sidebar could not be changed."))}
    end
  end

  # A pushed payload is client-chosen; swallow a malformed one here rather than
  # letting it fall through to a LiveView that has no clause for it.
  def handle_event("set_nav_preset", _params, socket), do: {:halt, socket}

  def handle_event(_event, _params, socket), do: {:cont, socket}
end
