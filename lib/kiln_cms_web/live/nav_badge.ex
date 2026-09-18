defmodule KilnCMSWeb.NavBadge do
  @moduledoc """
  A count on a sidebar nav item: the pill beside "Tasks" in
  `KilnCMSWeb.Layouts.console/1`, shrunk to a dot on the icon rail.

  Built the way `KilnCMSWeb.NotificationBell` is, for the same two reasons.
  The console layout is a *function* component that 43 LiveViews call, so the
  count is a LiveComponent that loads itself from the user and org the layout
  already has, rather than one more attribute on every call site. And it
  counts when its user or org changes (which includes the first mount) or when
  `refresh/1` asks — never on an ordinary re-render, which is every flash and
  every keystroke on a form.

  ## Which counts

  Only `:tasks`: the viewer's open tasks, the queue behind "Tasks". The Inbox
  has no badge on purpose. Its count is the bell's, one row up in the top bar;
  a second copy would show the same number twice and run the same query twice
  on every page.

  ## When it goes stale

  Every page counts on mount, so any navigation is fresh. Within a page it
  re-counts when a notification reaches this user
  (`KilnCMSWeb.LiveNotifications`) — which is how an assignment lands, because
  assigning a task notifies its assignee — and when the Tasks screen completes
  one. A task completed anywhere else (another tab, auto-complete on publish)
  shows on the next page.
  """
  use KilnCMSWeb, :live_component

  alias KilnCMS.CMS.Task

  # Past this the number has stopped being information; the screen-reader text
  # carries the real one.
  @badge_max 99

  @doc "The DOM id of the `kind` badge — also how `refresh/1` addresses it."
  @spec id(atom()) :: String.t()
  def id(kind) when is_atom(kind), do: "nav-badge-#{kind}"

  @doc """
  Re-count the `kind` badge.

  Called from the LiveView process — a LiveComponent receives no messages of
  its own. On a page that draws no such badge, LiveView logs its own "component
  does not exist" warning and moves on; see `KilnCMSWeb.LiveNotifications` on
  why that is left alone.
  """
  @spec refresh(atom()) :: :ok
  def refresh(kind) when is_atom(kind) do
    # A value that always changes, so LiveView sees new assigns and actually
    # calls `update/2`.
    send_update(__MODULE__, id: id(kind), refreshed_at: System.unique_integer([:monotonic]))
  end

  @impl true
  def update(assigns, socket) do
    scope_before = scope(socket.assigns)
    socket = assign(socket, assigns)

    if Map.has_key?(assigns, :refreshed_at) or scope(socket.assigns) != scope_before do
      %{kind: kind, user: user} = socket.assigns
      {:ok, assign(socket, :count, count(kind, user, socket.assigns[:org]))}
    else
      {:ok, socket}
    end
  end

  defp scope(assigns), do: {id_of(assigns[:user]), id_of(assigns[:org])}

  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_none), do: nil

  # Read as the viewer, so the task policy decides what counts. A failed read
  # counts zero, which hides the badge: it is chrome, and a console page must
  # not 500 because a count did (the same call `Notifications.unread_count/2`
  # makes for the bell).
  defp count(:tasks, %{id: user_id} = user, org) do
    Task
    |> Ash.Query.for_read(:for_assignee, %{assignee_id: user_id}, actor: user, tenant: org)
    # A count has no use for the action's due-date ordering.
    |> Ash.Query.unset(:sort)
    |> Ash.count(actor: user, tenant: org)
    |> case do
      {:ok, count} -> count
      _error -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The pill is decoration: capped, and hidden from assistive technology.
          The sentence beside it is what a screen reader hears, uncapped, as
          part of the link's name — "Tasks (3 open)". --%>
    <span id={@id} class="side-badge-slot" hidden={@count == 0}>
      <span class="side-badge" aria-hidden="true">{badge_text(@count)}</span>
      <span class="sr-only">{label(@kind, @count)}</span>
    </span>
    """
  end

  defp badge_text(count) when count > @badge_max, do: "#{@badge_max}+"
  defp badge_text(count), do: Integer.to_string(count)

  defp label(:tasks, count), do: ngettext("(%{count} open)", "(%{count} open)", count)
end
