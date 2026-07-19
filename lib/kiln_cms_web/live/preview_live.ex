defmodule KilnCMSWeb.PreviewLive do
  @moduledoc """
  Standalone, real-time preview of a Page/Post — opened in its own window from
  the editor. It loads the current content, then subscribes (native
  `Phoenix.PubSub`) to the editor's preview topic and re-renders on every edit,
  with no page reload. Editor/admin only.

  **Multiplayer (#343).** Multiple people can open the same preview and see each
  other: a live presence bar of who's watching (`Phoenix.Presence`), and each
  other's cursors moving over the preview in real time (native PubSub, sub-200ms
  on a LAN). An editor and a stakeholder can review the same draft together.

  For **public-site fidelity** the content is rendered through the same
  `Layouts.public` shell and `prose` article markup the live site uses (see
  `content_html/show_page.html.heex` / `show_post.html.heex`) via the shared
  `KilnCMSWeb.BlockComponents` — so the pop-out is a faithful preview, not just
  the raw blocks. A thin ribbon marks it as a draft preview.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.Presence

  @doc "PubSub topic the editor broadcasts on for a given content item."
  def topic(kind, id), do: "content_preview:#{kind}:#{id}"

  @impl true
  def mount(%{"kind" => kind, "id" => id}, _session, socket) do
    if ContentTypes.type?(kind) do
      user = socket.assigns.current_user
      record = ContentTypes.get_record!(kind, id, actor: user)

      socket =
        socket
        |> assign(:kind, kind)
        |> assign(:record_id, id)
        |> assign(:page_title, gettext("Preview: %{title}", title: record.title))
        |> assign(:excerpt?, ContentTypes.get!(kind).excerpt?)
        |> assign(:title, record.title)
        |> assign(:excerpt, Map.get(record, :excerpt))
        |> assign(:blocks, content_blocks(record))
        |> assign(:locale, record.locale)
        |> assign(:variants, locale_variants(kind, record, user))
        |> assign(:viewers, [])
        |> assign(:cursors, %{})
        |> assign(:viewer_key, nil)
        |> assign(:color, "#64748b")

      {:ok, maybe_join(socket, kind, id, user)}
    else
      {:ok, push_navigate(socket, to: ~p"/editor")}
    end
  end

  def mount(_params, _session, socket), do: {:ok, push_navigate(socket, to: ~p"/editor")}

  # On the connected mount, join the shared preview: subscribe to content
  # updates, presence diffs, and cursor moves, and announce ourselves.
  defp maybe_join(socket, kind, id, user) do
    if connected?(socket) do
      viewer_key = "#{user.id}:#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic(kind, id))
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_topic(kind, id))
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_cursor_topic(kind, id))
      Presence.track_preview_viewer(self(), kind, id, viewer_key, user)

      socket
      |> assign(:viewer_key, viewer_key)
      |> assign(:color, Presence.viewer_color(viewer_key))
      |> assign(:viewers, Presence.preview_viewers(kind, id))
    else
      socket
    end
  end

  # The record's locale siblings (same slug, any state the viewer may read),
  # for the shared locale switcher (#378). Scoped to the record's own org.
  defp locale_variants(kind, record, user) do
    ContentTypes.list!(kind,
      actor: user,
      tenant: record.org_id,
      query: [filter: [slug: record.slug], select: [:id, :locale]]
    )
    |> Enum.map(&%{id: &1.id, locale: &1.locale})
    |> Enum.sort_by(& &1.locale)
  rescue
    _ -> [%{id: record.id, locale: record.locale}]
  end

  defp content_blocks(record) do
    # Blocks are the typed union (Kiln v2); convert to the thin {type, content}
    # maps the shared BlockComponents preview renderer expects (columns recurse).
    record.blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
    |> BlockComponents.thin_blocks()
  end

  @impl true
  def handle_info({:preview_update, payload}, socket) do
    {:noreply,
     socket
     |> assign(:title, payload.title)
     |> assign(:blocks, payload.blocks)
     |> assign(:excerpt, Map.get(payload, :excerpt, socket.assigns.excerpt))}
  end

  # A viewer joined or left — refresh the presence bar and drop cursors for
  # anyone who left.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    viewers = Presence.preview_viewers(socket.assigns.kind, socket.assigns.record_id)
    live_keys = MapSet.new(viewers, & &1.key)

    cursors =
      Map.filter(socket.assigns.cursors, fn {key, _} -> MapSet.member?(live_keys, key) end)

    {:noreply, socket |> assign(:viewers, viewers) |> assign(:cursors, cursors)}
  end

  # Another viewer's cursor moved.
  def handle_info({:preview_cursor, cursor}, socket) do
    {:noreply, assign(socket, :cursors, Map.put(socket.assigns.cursors, cursor.key, cursor))}
  end

  def handle_info({:preview_cursor_gone, key}, socket) do
    {:noreply, assign(socket, :cursors, Map.delete(socket.assigns.cursors, key))}
  end

  # A co-viewer switched the shared locale (#378): everyone follows to the
  # sibling document's preview, where presence re-forms.
  def handle_info({:preview_switch, id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/editor/preview/#{socket.assigns.kind}/#{id}")}
  end

  # Ignore any unexpected message rather than crashing the preview process.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  # Our cursor moved (from the JS hook): broadcast it to the other viewers.
  # Coordinates are fractions (0..1) of the preview area, so they map across
  # different window sizes. `broadcast_from` so we never render our own cursor.
  def handle_event("cursor", %{"x" => x, "y" => y}, socket) do
    if socket.assigns.viewer_key do
      cursor = %{
        key: socket.assigns.viewer_key,
        name: viewer_name(socket),
        color: socket.assigns.color,
        x: clamp(x),
        y: clamp(y)
      }

      Phoenix.PubSub.broadcast_from(
        KilnCMS.PubSub,
        self(),
        Presence.preview_cursor_topic(socket.assigns.kind, socket.assigns.record_id),
        {:preview_cursor, cursor}
      )
    end

    {:noreply, socket}
  end

  # Switch every co-viewer (self included) to a locale sibling — broadcast on
  # the preview topic, so the whole group stays on the same variant (#378).
  # Only ids from the resolved sibling list are accepted.
  def handle_event("switch_variant", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.variants, &(&1.id == id)) and id != socket.assigns.record_id do
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        topic(socket.assigns.kind, socket.assigns.record_id),
        {:preview_switch, id}
      )
    end

    {:noreply, socket}
  end

  def handle_event("cursor_leave", _params, socket) do
    if socket.assigns.viewer_key do
      Phoenix.PubSub.broadcast_from(
        KilnCMS.PubSub,
        self(),
        Presence.preview_cursor_topic(socket.assigns.kind, socket.assigns.record_id),
        {:preview_cursor_gone, socket.assigns.viewer_key}
      )
    end

    {:noreply, socket}
  end

  defp viewer_name(socket) do
    Enum.find_value(socket.assigns.viewers, "Someone", fn v ->
      v.key == socket.assigns.viewer_key && v.name
    end)
  end

  defp clamp(value) when is_number(value), do: value |> max(0.0) |> min(1.0)
  defp clamp(_), do: 0.0

  # `* 100.0` (not `* 100`) forces a float: an edge coordinate arrives as the
  # JSON integer 0 or 1, and `float_to_binary/2` raises on an integer.
  defp pct(fraction), do: :erlang.float_to_binary(fraction * 100.0, decimals: 1) <> "%"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sticky top-0 z-20 flex items-center justify-between gap-2 bg-warning/90 px-4 py-1.5 text-xs font-medium text-warning-content">
      <div class="flex items-center gap-2">
        <span>{gettext("Draft preview — not the published page")}</span>
        <%!-- Shared locale switcher (#378): changing it moves every co-viewer,
              so the group always reviews the same language variant. --%>
        <form
          :if={length(@variants) > 1}
          id="preview-locale-form"
          phx-change="switch_variant"
          class="flex items-center"
        >
          <label for="preview-locale-switch" class="sr-only">{gettext("Locale")}</label>
          <select
            id="preview-locale-switch"
            name="id"
            class="select select-xs w-auto min-h-0 border-warning-content/40 bg-warning/60 font-medium uppercase"
          >
            <option :for={v <- @variants} value={v.id} selected={v.id == @record_id}>
              {v.locale}
            </option>
          </select>
        </form>
        <span :if={length(@variants) <= 1} class="font-semibold uppercase" data-role="locale">
          {@locale}
        </span>
      </div>
      <.presence_bar viewers={@viewers} />
    </div>
    <%!-- The cursor layer sits over the preview; the hook reports pointer moves
          as fractions of this box so they map across window sizes. --%>
    <div id="preview-surface" phx-hook="PreviewCursors" class="relative">
      <div class="pointer-events-none absolute inset-0 z-10">
        <span
          :for={{key, cursor} <- @cursors}
          :if={key != @viewer_key}
          id={"cursor-#{key}"}
          data-role="remote-cursor"
          class="absolute -translate-y-1 transition-all duration-75 ease-linear"
          style={"left:#{pct(cursor.x)};top:#{pct(cursor.y)}"}
        >
          <svg viewBox="0 0 16 16" class="size-4 drop-shadow" fill={cursor.color} aria-hidden="true">
            <path d="M0 0l5 12 2-5 5-2z" />
          </svg>
          <span
            class="ml-3 rounded px-1.5 py-0.5 text-[10px] font-medium text-white"
            style={"background-color:#{cursor.color}"}
          >
            {cursor.name}
          </span>
        </span>
      </div>

      <Layouts.public>
        <article class="prose max-w-none">
          <header :if={@excerpt?} class="mb-6">
            <h1 class="text-3xl font-bold tracking-tight">{@title}</h1>
            <p :if={@excerpt} class="mt-3 text-lg text-base-content/70">{@excerpt}</p>
          </header>
          <h1 :if={!@excerpt?} class="text-3xl font-bold tracking-tight">{@title}</h1>
          <div class="space-y-4" id="preview-blocks">
            <BlockComponents.render_block :for={block <- @blocks} block={block} />
          </div>
        </article>
      </Layouts.public>
    </div>
    """
  end

  attr :viewers, :list, required: true

  defp presence_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-1" aria-label={gettext("People viewing")}>
      <span
        :for={viewer <- @viewers}
        class="grid size-5 place-items-center rounded-full text-[10px] font-semibold text-white ring-1 ring-white/60"
        style={"background-color:#{viewer.color}"}
        title={viewer.name}
      >
        {String.first(viewer.name)}
      </span>
      <span :if={length(@viewers) > 1} class="ml-1 text-warning-content/80">
        {gettext("%{count} viewing", count: length(@viewers))}
      </span>
    </div>
    """
  end
end
