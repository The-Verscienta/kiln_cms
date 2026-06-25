defmodule KilnCMSWeb.PreviewLive do
  @moduledoc """
  Standalone, real-time preview of a Page/Post — opened in its own window from
  the editor. It loads the current content, then subscribes (native
  `Phoenix.PubSub`) to the editor's preview topic and re-renders on every edit,
  with no page reload. Editor/admin only.

  Renders without the editor chrome (no `Layouts.app`), via the shared
  `KilnCMSWeb.BlockComponents`.
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
      end

      {:ok,
       socket
       |> assign(:title, record.title)
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
  def handle_info({:preview_update, %{title: title, blocks: blocks}}, socket) do
    {:noreply, assign(socket, title: title, blocks: blocks)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article class="mx-auto max-w-3xl space-y-4 p-8">
      <h1 class="text-3xl font-bold">{@title}</h1>
      <BlockComponents.render_block :for={block <- @blocks} block={block} />
    </article>
    """
  end
end
