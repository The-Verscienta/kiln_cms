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

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.Presence

  @doc "PubSub topic the editor broadcasts on for a given content item."
  def topic(kind, id), do: "content_preview:#{kind}:#{id}"

  @impl true
  def mount(%{"kind" => kind, "id" => id}, _session, socket) do
    if ContentTypes.type?(kind) do
      user = socket.assigns.current_user
      # Scope the record read to the editor's current site (epic #336) so a
      # preview can only open that site's content.
      org = socket.assigns.current_org
      record = ContentTypes.get_record!(kind, id, actor: user, tenant: org)

      socket =
        socket
        |> assign(:kind, kind)
        |> assign(:record_id, id)
        |> assign(:page_title, gettext("Preview: %{title}", title: record.title))
        |> assign(:excerpt?, ContentTypes.get!(kind, org.id).excerpt?)
        |> assign(:title, record.title)
        |> assign(:excerpt, Map.get(record, :excerpt))
        |> assign(:blocks, content_blocks(record))
        |> assign(:locale, record.locale)
        |> assign(:variants, locale_variants(kind, record, user))
        |> assign(:viewers, [])
        |> assign(:cursors, %{})
        |> assign(:viewer_key, nil)
        |> assign(:color, "#64748b")
        |> assign(:comment_counts, comment_counts(kind, id, user, org))

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
  # A comment was added or (un)resolved anywhere — the editor, the API, another
  # viewer's window. Recount rather than adjusting in place: the broadcast says
  # *that* a block changed, not what it changed to, so a delta would drift on a
  # dropped message.
  def handle_info({:preview_comments_changed, _block_id}, socket) do
    counts =
      comment_counts(
        socket.assigns.kind,
        socket.assigns.record_id,
        socket.assigns.current_user,
        socket.assigns.current_org
      )

    {:noreply, assign(socket, :comment_counts, counts)}
  end

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
  def handle_event("switch_variant", %{"id" => id}, socket) when is_binary(id) do
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
            class="field-select w-auto min-h-0 border-warning-content/40 bg-warning/60 px-2 py-0.5 text-xs font-medium uppercase"
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

      <Layouts.public current_org={@current_org}>
        <article class="prose max-w-none">
          <header :if={@excerpt?} class="mb-6">
            <h1 class="text-3xl font-bold tracking-tight">{@title}</h1>
            <p :if={@excerpt} class="mt-3 text-lg text-base-content/70">{@excerpt}</p>
          </header>
          <h1 :if={!@excerpt?} class="text-3xl font-bold tracking-tight">{@title}</h1>
          <div class="space-y-4" id="preview-blocks">
            <%!-- `relative` on the wrapper, so the pin can sit in the margin
                  without `render_block/1` knowing anything about comments —
                  this surface mirrors public HTML, and the shared renderer has
                  to keep producing exactly that. --%>
            <div :for={block <- @blocks} class="relative" data-block-wrap={block[:id]}>
              <BlockComponents.render_block block={block} />
              <.comment_pin
                count={@comment_counts[block[:id]]}
                kind={@kind}
                record_id={@record_id}
                block_id={block[:id]}
              />
            </div>
          </div>
        </article>
      </Layouts.public>
    </div>
    """
  end

  attr :count, :integer, default: nil
  attr :kind, :string, required: true
  attr :record_id, :string, required: true
  attr :block_id, :string, default: nil

  # A marker, not a thread. The preview is meant to read like the published
  # page, so the discussion itself stays in the editor and this is the jump to
  # it — the same move as the editor's own "Edit this block on the page" link,
  # pointed the other way.
  defp comment_pin(%{count: nil} = assigns), do: ~H""

  defp comment_pin(assigns) do
    ~H"""
    <.link
      navigate={~p"/editor/content/#{@kind}/#{@record_id}?#{[comment: @block_id]}"}
      class="absolute -left-2 top-0 grid size-6 -translate-x-full place-items-center rounded-full bg-warning/20 text-[11px] font-semibold text-warning-ink ring-1 ring-warning/40 hover:bg-warning/30"
      title={
        ngettext(
          "%{count} open comment — open it in the editor",
          "%{count} open comments — open them in the editor",
          @count,
          count: @count
        )
      }
    >
      {@count}
    </.link>
    """
  end

  # Open threads per block, as `%{block_id => count}`. Resolved threads carry no
  # pin: a resolved discussion is finished, and leaving a marker for it would
  # make the margin unreadable on a document that has been through review.
  #
  # `nil` for a comment set that cannot be read (a viewer without comment
  # permission) rather than an error — the preview's job is to show the
  # document, and losing the pins is a smaller failure than losing the page.
  defp comment_counts(kind, record_id, actor, org) do
    kind
    |> to_string()
    |> CMS.list_comments_for!(record_id, actor: actor, tenant: org)
    |> Enum.filter(&(is_nil(&1.thread_id) and is_nil(&1.resolved_at)))
    |> Enum.reduce(%{}, fn comment, acc ->
      Map.update(acc, comment.block_id, 1, &(&1 + 1))
    end)
    |> reply_counts(kind, record_id, actor, org)
  rescue
    _error -> %{}
  end

  # A thread's pin shows the whole conversation's size, not just its root.
  defp reply_counts(roots, kind, record_id, actor, org) do
    open_blocks = Map.keys(roots)

    kind
    |> to_string()
    |> CMS.list_comments_for!(record_id, actor: actor, tenant: org)
    |> Enum.filter(&(not is_nil(&1.thread_id) and &1.block_id in open_blocks))
    |> Enum.reduce(roots, fn reply, acc ->
      Map.update(acc, reply.block_id, 1, &(&1 + 1))
    end)
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
