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

  ## Clicking an item marks it read on the way out

  `phx-click` fires on the component and the link then navigates, so the badge
  is already right when the editor arrives. The recipient's *other* open
  consoles follow through the resource's own broadcast.
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
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> load()}

  @impl true
  def handle_event("mark-read", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.current_user

    with {:ok, notification} <- Notifications.get_notification(id, actor: actor),
         {:ok, _marked} <- Notifications.mark_notification_read(notification, actor: actor) do
      {:noreply, load(socket)}
    else
      # Somebody else's id, or a row that has since gone. The policy already
      # refused it; there is nothing to report and nothing to change.
      _refused -> {:noreply, socket}
    end
  end

  def handle_event("mark-all-read", _params, socket) do
    Notifications.mark_all_read(socket.assigns.current_user, socket.assigns.current_org)
    {:noreply, load(socket)}
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
              <.link
                navigate={Link.editor_path(notification)}
                phx-click="mark-read"
                phx-value-id={notification.id}
                phx-target={@myself}
                class={["bell-item", is_nil(notification.read_at) && "bell-item-unread"]}
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
              </.link>
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
