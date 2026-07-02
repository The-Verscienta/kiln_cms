defmodule KilnCMSWeb.PreviewLive do
  @moduledoc """
  Standalone, real-time preview of a Page/Post — opened in its own window from
  the editor. It loads the current content, then subscribes (native
  `Phoenix.PubSub`) to the editor's preview topic and re-renders on every edit,
  with no page reload. Editor/admin only.

  For **public-site fidelity** the content is rendered through the same
  `Layouts.public` shell and `prose` article markup the live site uses (see
  `content_html/show_page.html.heex` / `show_post.html.heex`) via the shared
  `KilnCMSWeb.BlockComponents` — so the pop-out is a faithful preview, not just
  the raw blocks. A thin ribbon marks it as a draft preview.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.BlockComponents

  @doc "PubSub topic the editor broadcasts on for a given content item."
  def topic(kind, id), do: "content_preview:#{kind}:#{id}"

  @impl true
  def mount(%{"kind" => kind, "id" => id}, _session, socket) do
    if ContentTypes.type?(kind) do
      record = ContentTypes.get_record!(kind, id, actor: socket.assigns.current_user)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic(kind, id))
        # Announce this window so editors only build/broadcast preview
        # payloads while someone is actually watching.
        KilnCMSWeb.Presence.track_preview(self(), kind, id)
      end

      {:ok,
       socket
       |> assign(:kind, kind)
       |> assign(:page_title, gettext("Preview: %{title}", title: record.title))
       |> assign(:excerpt?, ContentTypes.get!(kind).excerpt?)
       |> assign(:title, record.title)
       |> assign(:excerpt, Map.get(record, :excerpt))
       |> assign(:blocks, content_blocks(record))}
    else
      {:ok, push_navigate(socket, to: ~p"/editor")}
    end
  end

  def mount(_params, _session, socket), do: {:ok, push_navigate(socket, to: ~p"/editor")}

  defp content_blocks(record) do
    # Blocks are the typed union (Kiln v2); convert to the thin {type, content}
    # maps the shared BlockComponents preview renderer expects.
    record.blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
    |> Enum.map(&%{type: to_string(&1.type), content: &1.content})
  end

  @impl true
  def handle_info({:preview_update, payload}, socket) do
    {:noreply,
     socket
     |> assign(:title, payload.title)
     |> assign(:blocks, payload.blocks)
     |> assign(:excerpt, Map.get(payload, :excerpt, socket.assigns.excerpt))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 bg-warning/90 px-4 py-1.5 text-center text-xs font-medium text-warning-content">
      {gettext("Draft preview — not the published page")}
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
    """
  end
end
