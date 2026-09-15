defmodule KilnCMSWeb.NotificationBell do
  @moduledoc """
  The console top bar's notification bell (#1320): an unread badge and a
  dropdown of recent items, each deep-linking to the block, comment or task it
  concerns.

  ## A LiveComponent, not assigns on 43 call sites

  `KilnCMSWeb.Layouts.console/1` is a *function* component that 43 LiveViews
  call with five attributes each. Threading bell state through it would mean an
  attribute on all 43 and a new one on every console page written afterwards —
  a contract nobody would remember on page 44. So the layout renders this as a
  LiveComponent, which loads and owns its own state from the `current_user` and
  `current_org` the layout is already given.

  A LiveComponent has no process of its own and cannot subscribe to PubSub,
  which is the gap `KilnCMSWeb.LiveNotifications` fills: the parent LiveView
  holds the subscription and `send_update/2` (via `refresh/0`) tells this
  component to re-read.

  Rows are read under the signed-in user as the actor, and the resource's read
  policy is self-only with no admin bypass — so the bell cannot show a row that
  is not the viewer's even if the layout were handed the wrong user.

  ## Read, not unread

  The dropdown lists the most recent items whether or not they are read, and
  marking one read does not remove it. A list that empties itself while you
  look at it takes each item's deep link with it, which is the one thing a
  notification is for. The badge counts the unread subset; `/editor/inbox` is
  the full list, and this is a window onto the top of it.

  ## Clicking an item marks it read, *then* navigates

  An item is a button whose handler marks the row read and only then
  `push_navigate`s to its deep link. It was a `<.link navigate>` carrying a
  `phx-click`, which never marked anything: LiveView's client handles a live
  link by swapping the main view first and running the link's `phx-click`
  afterwards, by which point this component — and the `phx-target` the event
  was addressed to — has gone with the old page. The destination is taken
  from the row the server looked up, never from the client.

  The recipient's *other* open consoles follow through the resource's own
  broadcast.

  ## It reads on a refresh, not on every render

  `update/2` runs whenever the parent LiveView re-renders the layout — a
  flash, a form change, anything — and the layout hands over the same user
  and org every time. Re-reading on each of those put a count and a list query
  on every console render. It re-reads when `refresh/0` asks, and when the
  user or org it was given actually changes (which includes the first mount).
  """
  use KilnCMSWeb, :live_component

  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link
  alias KilnCMSWeb.NotificationText

  @id "notification-bell"

  # How many items the dropdown shows before deferring to the inbox. Eight
  # fits the panel without scrolling on a laptop, and a backlog belongs in the
  # inbox — one click below.
  @recent 8

  # The badge stops counting here and reads "8+". Past that the number has
  # stopped being information, and the accessible label carries the real one
  # anyway.
  @badge_max 9

  @doc "The component's DOM id — also how `send_update/2` addresses it."
  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Tell the bell to re-read itself.

  Called from the LiveView process that holds the PubSub subscription
  (`KilnCMSWeb.LiveNotifications`), which is the only place that can: a
  LiveComponent receives no messages of its own.
  """
  @spec refresh() :: :ok
  def refresh do
    # A monotonically changing assign, so LiveView sees the component's assigns
    # as changed and actually invokes `update/2`. Without it, a second
    # notification with identical assigns would be a no-op.
    send_update(__MODULE__, id: @id, refreshed_at: System.unique_integer([:monotonic]))
  end

  @impl true
  def update(assigns, socket) do
    scope_before = scope(socket.assigns)
    socket = assign(socket, assigns)

    if Map.has_key?(assigns, :refreshed_at) or scope(socket.assigns) != scope_before do
      {:ok, load(socket)}
    else
      {:ok, socket}
    end
  end

  defp scope(assigns), do: {id_of(assigns[:current_user]), id_of(assigns[:current_org])}

  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_none), do: nil

  @impl true
  def handle_event("open", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.current_user
    tenant = socket.assigns[:current_org]

    case Notifications.get_notification(id, actor: actor, tenant: tenant) do
      {:ok, notification} ->
        # Best-effort: a row that fails to mark read is still a link worth
        # following, and the editor would rather arrive than be stopped here.
        _marked = Notifications.mark_notification_read(notification, actor: actor, tenant: tenant)
        {:noreply, push_navigate(socket, to: Link.editor_path(notification))}

      # Somebody else's id, or a row that has since gone. The policy already
      # refused it; there is nothing to open.
      _refused ->
        {:noreply, socket}
    end
  end

  # No local reload: the sweep announces once on this user's topic, and every
  # live_session that renders the console shell mounts `LiveNotifications`,
  # so that announcement is what re-reads the bell (and the inbox list, when
  # the bell is on that page). Reloading here as well ran both queries twice.
  def handle_event("mark-all-read", _params, socket) do
    _result =
      Notifications.mark_all_read(socket.assigns.current_user, socket.assigns[:current_org])

    {:noreply, socket}
  end

  # `KilnCMSWeb.MalformedEvent` injects a catch-all into every Kiln *LiveView*,
  # not into LiveComponents, so this one carries its own (#764): a pushed
  # payload is client-chosen, and `%{"id" => true}` must be a no-op rather
  # than a FunctionClauseError that kills the page's chrome.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    user = socket.assigns.current_user
    org = socket.assigns[:current_org]

    socket
    |> assign(:unread_count, Notifications.unread_count(user, org))
    |> assign(:notifications, Notifications.recent(user, org, @recent))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bell">
      <%!-- A <details>, like the sidebar's account menu: it opens before the
            socket connects, `ignore_attributes` stops LiveView's next patch
            stripping the client-set `open`, and `data-autoclose` opts it into
            app.js's outside-click/Escape handling. --%>
      <details
        id={"#{@id}-menu"}
        class="bell-root"
        data-autoclose
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary class="bell-trigger" aria-label={bell_label(@unread_count)}>
          <.icon name="hero-bell" class="size-5" />
          <%!-- The badge is decoration — capped, and hidden from assistive
                technology, because the summary's own label above carries the
                real, uncapped number. A count nobody can hear is not a count. --%>
          <span :if={@unread_count > 0} class="bell-badge" aria-hidden="true">
            {unread_badge(@unread_count)}
          </span>
        </summary>

        <div class="bell-panel">
          <div class="bell-head">
            <span class="font-semibold">{gettext("Notifications")}</span>
            <button
              :if={@unread_count > 0}
              type="button"
              phx-click="mark-all-read"
              phx-target={@myself}
              class="bell-action"
            >
              {gettext("Mark all read")}
            </button>
          </div>

          <p :if={@notifications == []} class="bell-empty">
            {gettext("Nothing yet.")}
          </p>

          <ul :if={@notifications != []} class="bell-list">
            <li :for={notification <- @notifications}>
              <%!-- A button, not a live link — see the moduledoc on why a
                    `phx-click` on a `navigate` link never reaches this
                    component. `data-guard-nav` puts it back under the
                    editor's unsaved-changes confirm (app.js `UnsavedGuard`),
                    which a live link had for free and a server-side
                    `push_navigate` does not. --%>
              <button
                type="button"
                data-guard-nav
                phx-click="open"
                phx-value-id={notification.id}
                phx-target={@myself}
                class={[
                  "bell-item w-full text-left",
                  is_nil(notification.read_at) && "bell-item-unread"
                ]}
              >
                <span class="bell-item-head">
                  <span class="truncate font-medium">
                    {NotificationText.headline(notification)}
                  </span>
                  <%!-- `CoreComponents.ago/1` — the shared coarse "how long
                        ago" the backup panel and the push-device list already
                        use. The exact time rides along in `datetime`. --%>
                  <time
                    datetime={DateTime.to_iso8601(notification.inserted_at)}
                    class="bell-item-time"
                  >
                    {ago(notification.inserted_at)}
                  </time>
                </span>
                <span class="bell-item-sub">{notification.title}</span>
              </button>
            </li>
          </ul>

          <.link navigate={~p"/editor/inbox"} class="bell-foot">
            {gettext("Open inbox")}
          </.link>
        </div>
      </details>
    </div>
    """
  end

  @doc """
  The badge's own text, capped at `8+`.

  Public so the test can pin the cap without seeding ten notifications. Named
  `unread_badge` rather than `badge` because `KilnCMSWeb.CoreComponents.badge/1`
  — the status pill — is imported here.
  """
  @spec unread_badge(non_neg_integer()) :: String.t()
  def unread_badge(count) when count >= @badge_max, do: "#{@badge_max - 1}+"
  def unread_badge(count), do: Integer.to_string(count)

  # The accessible name carries the real number, uncapped: "8+" is a
  # space-saving glyph for the eye, not an answer for a screen reader.
  defp bell_label(0), do: gettext("Notifications")

  defp bell_label(count),
    do:
      ngettext(
        "Notifications, %{count} unread",
        "Notifications, %{count} unread items",
        count,
        count: count
      )
end
