defmodule KilnCMSWeb.EditorLive do
  @moduledoc """
  Content list / editor home (`/editor`) — browse pages with their workflow
  state, create a new page, jump into the block editor, and publish/unpublish
  inline. Editor/admin only. (Posts get an editor in a follow-up increment.)
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:actor, socket.assigns.current_user) |> load_pages()}
  end

  defp load_pages(socket) do
    assign(
      socket,
      :pages,
      CMS.list_pages!(actor: socket.assigns.actor, query: [sort: [updated_at: :desc]])
    )
  end

  @impl true
  def handle_event("new_page", _params, socket) do
    page =
      CMS.create_page!(
        %{title: "Untitled page", slug: "untitled-#{System.unique_integer([:positive])}"},
        actor: socket.assigns.actor
      )

    {:noreply, push_navigate(socket, to: ~p"/editor/pages/#{page.id}")}
  end

  def handle_event("publish", %{"id" => id}, socket),
    do: {:noreply, transition(socket, id, :publish)}

  def handle_event("unpublish", %{"id" => id}, socket),
    do: {:noreply, transition(socket, id, :unpublish)}

  defp transition(socket, id, action) do
    actor = socket.assigns.actor
    page = CMS.get_page!(id, actor: actor)

    result =
      case action do
        :publish -> CMS.publish_page(page, %{}, actor: actor)
        :unpublish -> CMS.unpublish_page(page, %{}, actor: actor)
      end

    case result do
      {:ok, _} -> socket |> load_pages() |> put_flash(:info, "Updated.")
      _ -> put_flash(socket, :error, "That action isn't allowed right now.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold">Content</h1>
          <.button type="button" phx-click="new_page" variant="primary">New page</.button>
        </div>

        <p :if={@pages == []} class="text-sm text-base-content/60">
          No pages yet. Create your first one.
        </p>

        <ul
          :if={@pages != []}
          class="divide-y divide-base-content/10 rounded border border-base-content/10"
        >
          <li :for={page <- @pages} id={"page-#{page.id}"} class="flex items-center gap-4 p-3">
            <div class="min-w-0 flex-1">
              <.link navigate={~p"/editor/pages/#{page.id}"} class="font-medium hover:underline">
                {page.title}
              </.link>
              <p class="truncate text-xs text-base-content/50">/{page.slug}</p>
            </div>
            <.state_badge state={page.state} />
            <div class="flex items-center gap-2">
              <button
                :if={page.state in [:draft, :in_review]}
                type="button"
                phx-click="publish"
                phx-value-id={page.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                Publish
              </button>
              <button
                :if={page.state == :published}
                type="button"
                phx-click="unpublish"
                phx-value-id={page.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                Unpublish
              </button>
              <.link
                navigate={~p"/editor/pages/#{page.id}"}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                Edit
              </.link>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    color =
      case assigns.state do
        :published -> "bg-success/15 text-success"
        :in_review -> "bg-warning/15 text-warning"
        :archived -> "bg-base-content/10 text-base-content/60"
        _ -> "bg-info/15 text-info"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-xs font-medium", @color]}>{@state}</span>
    """
  end
end
