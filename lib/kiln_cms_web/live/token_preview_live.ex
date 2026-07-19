defmodule KilnCMSWeb.TokenPreviewLive do
  @moduledoc """
  The **shared** human view of a token preview link (#379).

  `/preview/:token/live` is the browser face of the headless draft surface
  (`/preview/:token`, JSON): external stakeholders *without an editor account*
  open the same short-lived signed link and land here. It reuses the multiplayer
  machinery from the editor pop-out (#343) — the **same** presence and cursor
  topics for the underlying `{kind, id}` — so an editor in
  `/editor/preview/:kind/:id` and a token guest see each other's presence and
  cursors, and the guest's view live-updates as the editor types (the shared
  `{:preview_update, …}` broadcasts).

  Guests are anonymous: they join as "Guest N" and may pick a display name
  (never an email — nothing account-related exists to leak). The signed token
  authorizes the read exactly like the JSON surface (`authorize?: false` after
  `PreviewToken.verify/1`), the tight `:preview` rate limit still fronts the
  route, and an invalid/expired token renders a dead-link notice — never
  content.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.Presence
  alias KilnCMSWeb.PreviewLive

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    with {:ok, %{type: type, id: id}} <- PreviewToken.verify(token),
         kind = to_string(type),
         true <- ContentTypes.type?(kind),
         {:ok, record} <- ContentTypes.get_record(kind, id, authorize?: false) do
      socket =
        socket
        |> assign(:invalid?, false)
        |> assign(:kind, kind)
        |> assign(:record_id, id)
        |> assign(:page_title, gettext("Preview: %{title}", title: record.title))
        |> assign(:excerpt?, ContentTypes.get!(kind).excerpt?)
        |> assign(:title, record.title)
        |> assign(:excerpt, Map.get(record, :excerpt))
        |> assign(:blocks, content_blocks(record))
        |> assign(:viewers, [])
        |> assign(:cursors, %{})
        |> assign(:viewer_key, nil)
        |> assign(:guest_name, nil)
        |> assign(:color, "#64748b")

      {:ok, maybe_join(socket, kind, id)}
    else
      # Invalid/expired/tampered token, or the document is gone: a dead-link
      # notice — never content, and no redirect target to probe.
      _ -> {:ok, assign(socket, :invalid?, true) |> assign(:page_title, gettext("Preview"))}
    end
  end

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :invalid?, true) |> assign(:page_title, gettext("Preview"))}

  # On the connected mount, join the same shared preview session the editor
  # pop-out uses: content updates, presence diffs, cursor moves.
  defp maybe_join(socket, kind, id) do
    if connected?(socket) do
      viewer_key = "guest:#{System.unique_integer([:positive])}"
      guest_name = "Guest #{:erlang.phash2(viewer_key, 90) + 10}"

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic(kind, id))
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_topic(kind, id))
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.preview_cursor_topic(kind, id))
      Presence.track_preview_viewer(self(), kind, id, viewer_key, %{name: guest_name})

      socket
      |> assign(:viewer_key, viewer_key)
      |> assign(:guest_name, guest_name)
      |> assign(:color, Presence.viewer_color(viewer_key))
      |> assign(:viewers, Presence.preview_viewers(kind, id))
    else
      socket
    end
  end

  defp content_blocks(record) do
    record.blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
    |> BlockComponents.thin_blocks()
  end

  # The editor saved/typed — live-update the guest's view (same payload the
  # pop-out preview consumes).
  @impl true
  def handle_info({:preview_update, payload}, socket) do
    {:noreply,
     socket
     |> assign(:title, payload.title)
     |> assign(:blocks, payload.blocks)
     |> assign(:excerpt, Map.get(payload, :excerpt, socket.assigns.excerpt))}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    viewers = Presence.preview_viewers(socket.assigns.kind, socket.assigns.record_id)
    live_keys = MapSet.new(viewers, & &1.key)

    cursors =
      Map.filter(socket.assigns.cursors, fn {key, _} -> MapSet.member?(live_keys, key) end)

    {:noreply, socket |> assign(:viewers, viewers) |> assign(:cursors, cursors)}
  end

  def handle_info({:preview_cursor, cursor}, socket) do
    {:noreply, assign(socket, :cursors, Map.put(socket.assigns.cursors, cursor.key, cursor))}
  end

  def handle_info({:preview_cursor_gone, key}, socket) do
    {:noreply, assign(socket, :cursors, Map.delete(socket.assigns.cursors, key))}
  end

  # Editor-side messages a guest must not follow (e.g. `{:preview_switch, id}`
  # navigates editors to /editor/... routes a guest can't open) — ignore
  # anything unexpected rather than crashing or leaking navigation.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cursor", %{"x" => x, "y" => y}, socket) do
    if socket.assigns.viewer_key do
      cursor = %{
        key: socket.assigns.viewer_key,
        name: socket.assigns.guest_name,
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

  # The guest picked a display name — cap it, update presence (co-viewers see
  # the rename via the diff), and use it for future cursor broadcasts.
  def handle_event("rename", %{"name" => name}, socket) do
    name = name |> String.trim() |> String.slice(0, 40)

    if socket.assigns.viewer_key && name != "" do
      Presence.rename_preview_viewer(
        self(),
        socket.assigns.kind,
        socket.assigns.record_id,
        socket.assigns.viewer_key,
        name
      )

      {:noreply, assign(socket, :guest_name, name)}
    else
      {:noreply, socket}
    end
  end

  defp clamp(value) when is_number(value), do: value |> max(0.0) |> min(1.0)
  defp clamp(_), do: 0.0

  defp pct(fraction), do: :erlang.float_to_binary(fraction * 100.0, decimals: 1) <> "%"

  @impl true
  def render(%{invalid?: true} = assigns) do
    ~H"""
    <div class="mx-auto max-w-md px-6 py-24 text-center">
      <h1 class="text-xl font-semibold">{gettext("This preview link has expired")}</h1>
      <p class="mt-3 text-base-content/70">
        {gettext("Preview links are short-lived. Ask the editor who shared it for a fresh one.")}
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="sticky top-0 z-20 flex items-center justify-between gap-2 bg-warning/90 px-4 py-1.5 text-xs font-medium text-warning-content">
      <span>{gettext("Shared draft preview — not the published page")}</span>
      <div class="flex items-center gap-3">
        <form
          :if={@viewer_key}
          id="guest-name-form"
          phx-submit="rename"
          class="flex items-center gap-1"
        >
          <label for="guest-name" class="sr-only">{gettext("Your name")}</label>
          <input
            id="guest-name"
            name="name"
            value={@guest_name}
            maxlength="40"
            class="input input-xs w-28 min-h-0 border-warning-content/40 bg-warning/60"
          />
          <button type="submit" class="btn btn-xs btn-ghost">{gettext("Set name")}</button>
        </form>
        <.presence_bar viewers={@viewers} />
      </div>
    </div>
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
