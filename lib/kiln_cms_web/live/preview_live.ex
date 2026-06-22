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

  alias KilnCMS.CMS
  alias KilnCMSWeb.BlockComponents

  @doc "PubSub topic the editor broadcasts on for a given content item."
  def topic(kind, id), do: "content_preview:#{kind}:#{id}"

  @impl true
  def mount(%{"kind" => kind, "id" => id}, _session, socket) when kind in ~w(page post) do
    record = fetch!(kind, id, socket.assigns.current_user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic(kind, id))
    end

    {:ok,
     socket
     |> assign(:title, record.title)
     |> assign(:blocks, content_blocks(record))}
  end

  def mount(_params, _session, socket), do: {:ok, push_navigate(socket, to: ~p"/editor")}

  defp fetch!("page", id, actor), do: CMS.get_page!(id, actor: actor)
  defp fetch!("post", id, actor), do: CMS.get_post!(id, actor: actor)

  defp content_blocks(record) do
    record.blocks
    |> List.wrap()
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
