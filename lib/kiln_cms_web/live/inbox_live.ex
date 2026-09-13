defmodule KilnCMSWeb.InboxLive do
  @moduledoc """
  The notification inbox (`/editor/inbox`, #1320) — everything the console has
  told this editor about, newest first, with mark-read and mark-all-read.

  The list the bell's dropdown is a window onto: same rows, same deep links,
  no cap. Rows are read under the signed-in user as the actor, and
  `KilnCMS.Notifications.Notification`'s read policy is self-only with no admin
  bypass, so this page cannot show anybody else's inbox.

  ## Every row is a link into the work

  A notification whose only content is its own text is a worse email. So each
  row navigates to the thing it concerns, via
  `KilnCMS.Notifications.Link.editor_path/1`: the document for a lifecycle
  event, and for a comment or a block-anchored task the document plus
  `?comment=<block_id>`, which `ContentEditorLive` reads at mount to open that
  block's thread. That param is the console's only durable block anchor —
  heading `id`s exist solely in public delivery, and the editor's own block
  cards are keyed by position — see that module.

  ## Read items stay

  `?filter=unread` narrows to what is outstanding, but `all` is the default:
  the inbox is a record of what happened, and a list that empties itself takes
  each item's deep link with it. Marking read is therefore reversible from the
  same row.
  """
  use KilnCMSWeb, :live_view

  @behaviour KilnCMSWeb.LiveNotifications

  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link
  alias KilnCMSWeb.NotificationText

  # One page's worth. Deliberately not paginated: an editor's notification
  # history is read at the top or not at all, and a "load more" on a list
  # whose whole job is to be dismissed is a control nobody presses. The window
  # is generous enough that hitting the end means the backlog is real.
  @window 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Inbox"))
     |> assign(:filter, :all)
     |> load_notifications()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:filter, filter_param(params["filter"])) |> load_notifications()}
  end

  # `all` is the default because a filter that hides rows by default hides
  # what happened — the same call `TaskLive` makes about its own scopes.
  defp filter_param("unread"), do: :unread
  defp filter_param(_all_or_unknown), do: :all

  # Called by `KilnCMSWeb.LiveNotifications`' hook when a notification lands or
  # is read in another session, instead of a `handle_info/2` clause — see that
  # module on why the hook halts.
  @impl KilnCMSWeb.LiveNotifications
  def notifications_changed(socket), do: load_notifications(socket)

  @impl true
  def handle_event("mark-read", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, mark(socket, id, &Notifications.mark_notification_read/2)}
  end

  def handle_event("mark-unread", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, mark(socket, id, &Notifications.mark_notification_unread/2)}
  end

  def handle_event("mark-all-read", _params, socket) do
    marked = Notifications.mark_all_read(socket.assigns.current_user, socket.assigns.current_org)

    {:noreply,
     socket
     |> put_flash(
       :info,
       ngettext("Marked %{count} notification read", "Marked %{count} notifications read", marked)
     )
     |> load_notifications()}
  end

  # The guards above are half of #764; the other half — the catch-all that
  # turns an unmatched shape into a no-op instead of a FunctionClauseError —
  # is injected into every Kiln LiveView by `KilnCMSWeb.MalformedEvent`, so
  # this module deliberately has none of its own.

  # The id comes from the client, so it is looked up rather than trusted: the
  # read is authorized as this user, and the resource's self-only policy means
  # another user's id simply is not found.
  defp mark(socket, id, fun) do
    actor = socket.assigns.current_user

    with {:ok, notification} <- Notifications.get_notification(id, actor: actor),
         {:ok, _updated} <- fun.(notification, actor: actor) do
      load_notifications(socket)
    else
      _refused -> socket
    end
  end

  defp load_notifications(socket) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org

    socket
    |> assign(:notifications, visible(user, org, socket.assigns.filter))
    |> assign(:unread_count, Notifications.unread_count(user, org))
  end

  # The unread filter reads the unread action rather than filtering the window
  # in memory: a backlog longer than `@window` would otherwise hide the oldest
  # unread items behind newer read ones, which is precisely the case the filter
  # exists for.
  defp visible(user, org, :unread), do: Notifications.recent_unread(user, org, @window)
  defp visible(user, org, :all), do: Notifications.recent(user, org, @window)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:inbox}
      container_class="mx-auto max-w-3xl"
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">{gettext("Inbox")}</h1>
          <button
            :if={@unread_count > 0}
            type="button"
            phx-click="mark-all-read"
            class="btn btn-sm btn-default"
          >
            {gettext("Mark all read")}
          </button>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.link
            :for={
              {value, label} <- [
                {:all, gettext("All")},
                {:unread, unread_label(@unread_count)}
              ]
            }
            patch={filter_path(value)}
            class={[
              "rounded-full border px-2.5 py-0.5 text-xs",
              @filter == value && "border-primary bg-primary/10 text-primary",
              @filter != value && "border-base-content/20 hover:bg-base-200"
            ]}
          >
            {label}
          </.link>
        </div>

        <div class="card divide-y divide-base-content/10">
          <p :if={@notifications == []} class="p-4 text-sm text-base-content/60">
            {empty_message(@filter)}
          </p>
          <.row :for={notification <- @notifications} notification={notification} />
        </div>
      </div>
    </Layouts.console>
    """
  end

  attr :notification, :map, required: true

  # The whole row is the link, with the read toggle beside it rather than
  # inside it: a button nested in an anchor is not a control any assistive
  # technology can describe, and clicking "mark unread" must not also navigate.
  defp row(assigns) do
    ~H"""
    <div class={[
      "flex items-start gap-3 p-4",
      is_nil(@notification.read_at) && "bg-primary/5"
    ]}>
      <span
        class={[
          "mt-1.5 size-2 shrink-0 rounded-full",
          if(is_nil(@notification.read_at), do: "bg-primary", else: "bg-transparent")
        ]}
        aria-hidden="true"
      ></span>

      <.link navigate={Link.editor_path(@notification)} class="min-w-0 flex-1 space-y-0.5">
        <p class="flex flex-wrap items-baseline gap-x-2">
          <span class="text-sm font-medium">{NotificationText.headline(@notification)}</span>
          <%!-- `CoreComponents.ago/1` — the shared coarse "how long ago" the
                backup panel and the push-device list already use. The exact
                time rides along in `datetime` for anyone who needs it. --%>
          <time
            datetime={DateTime.to_iso8601(@notification.inserted_at)}
            class="text-xs text-base-content/50"
          >
            {ago(@notification.inserted_at)}
          </time>
        </p>
        <p class="truncate text-sm text-base-content/70">{@notification.title}</p>
        <p :if={@notification.excerpt} class="line-clamp-2 text-xs text-base-content/60 italic">
          {@notification.excerpt}
        </p>
      </.link>

      <button
        type="button"
        phx-click={if is_nil(@notification.read_at), do: "mark-read", else: "mark-unread"}
        phx-value-id={@notification.id}
        class="shrink-0 rounded-md px-2 py-1 text-xs text-base-content/60 hover:bg-base-200 hover:text-base-content"
      >
        {if is_nil(@notification.read_at), do: gettext("Mark read"), else: gettext("Mark unread")}
      </button>
    </div>
    """
  end

  defp filter_path(:unread), do: ~p"/editor/inbox?filter=unread"
  defp filter_path(_all), do: ~p"/editor/inbox"

  defp unread_label(0), do: gettext("Unread")
  defp unread_label(count), do: gettext("Unread (%{count})", count: count)

  defp empty_message(:unread), do: gettext("Nothing unread.")

  defp empty_message(_all),
    do:
      gettext("Nothing yet. Review requests, comments, mentions and task assignments land here.")
end
