defmodule KilnCMSWeb.LiveNotifications do
  @moduledoc """
  Keeps notification surfaces live across the console (#1320).

  An `on_mount` hook on the `:editor_routes` and `:admin_routes` live_sessions:
  it subscribes the LiveView process to the signed-in user's notification topic
  (`KilnCMS.Notifications.topic/1`) and attaches a `handle_info` hook that
  reloads whichever surfaces on the page show notifications — the top bar's
  bell on every console page, and the list on `/editor/inbox`.

  One line in the router covers every console page, present and future — which
  is the point. The alternative was a `subscribe` call and a `handle_info`
  clause in each of the 43 LiveViews that render the console shell, i.e. a
  contract nobody would remember on page 44.

  ## Why the bell needs this at all

  `KilnCMSWeb.NotificationBell` is a LiveComponent, and a LiveComponent has no
  process of its own — it cannot subscribe to PubSub or receive a message. The
  subscription therefore has to live in the parent LiveView, which is what this
  hook puts there; `NotificationBell.refresh/0` then reaches the component
  through `send_update/2`.

  Three pages in these live_sessions render no console shell at all, on
  purpose — `PreviewLive`, `InContextEditLive` and `PresentationLive` are
  full-bleed editing surfaces. They have no bell, so a notification arriving
  while one is open logs LiveView's own `send_update failed because
  component … does not exist` warning. That is LiveView's documented
  not-an-error path (its source says "only a warning, because there can be
  race conditions where a component is removed before a `send_update`
  happens"), and it is left alone deliberately: the alternatives are a
  process-dictionary flag set from inside the component, or the 43 per-page
  opt-ins this hook exists to avoid.

  ## The hook halts, so pages opt in explicitly

  `attach_hook/4` handlers run *before* the LiveView's own `handle_info/2`, and
  this one returns `:halt`. It has to: most console LiveViews export
  `handle_info/2` for their own PubSub with no catch-all clause, so letting
  `:notifications_changed` through would raise a `FunctionClauseError` and kill
  whatever page the editor happened to be on when a comment landed.

  A page that *does* show notifications therefore says so by implementing
  `c:notifications_changed/1` rather than by matching the message:

      @behaviour KilnCMSWeb.LiveNotifications

      @impl KilnCMSWeb.LiveNotifications
      def notifications_changed(socket), do: load_notifications(socket)

  ## The message carries nothing

  `:notifications_changed` is content-free by design. Each surface re-reads
  under its own actor and tenant, so a user with two consoles open on two
  sites cannot be handed the other site's row by a broadcast — see
  `KilnCMS.Notifications.topic/1`.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias KilnCMS.Notifications
  alias KilnCMSWeb.NotificationBell

  @doc """
  Reload this page's notification surface. Return the updated socket.

  Implement it on a console LiveView that renders notifications itself (the
  inbox). Called instead of `handle_info/2` — see the moduledoc on why the
  hook halts.
  """
  @callback notifications_changed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()

  @doc """
  Subscribe to the signed-in user's notification topic.

  A no-op without a signed-in user (the hook runs in a live_session that
  requires one, but it must not crash the sign-in redirect on the way out) and
  on the disconnected mount, where there is no process to deliver to.
  """
  def on_mount(:notifications, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} when is_binary(user_id) ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, Notifications.topic(user_id))
        end

        {:cont, attach_hook(socket, :notifications, :handle_info, &refresh/2)}

      _signed_out ->
        {:cont, socket}
    end
  end

  defp refresh(:notifications_changed, socket) do
    # The bell is on every console page; the page-level surface is opt-in.
    NotificationBell.refresh()
    {:halt, reload_page(socket)}
  end

  defp refresh(_message, socket), do: {:cont, socket}

  defp reload_page(%{view: view} = socket) do
    if Code.ensure_loaded?(view) and function_exported?(view, :notifications_changed, 1) do
      view.notifications_changed(socket)
    else
      socket
    end
  end
end
