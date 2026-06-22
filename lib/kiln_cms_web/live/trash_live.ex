defmodule KilnCMSWeb.TrashLive do
  @moduledoc """
  Trash (`/editor/trash`) — browse soft-deleted pages/posts (AshArchival sets
  `archived_at` on delete) and restore them. Admin-only, mirroring the
  destroy/restore policy on the resources.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok, socket |> assign(:actor, actor) |> load_items()}
    else
      {:ok, push_navigate(socket, to: ~p"/editor")}
    end
  end

  # Soft-deleted pages and posts merged into `{kind, record}` tuples, newest
  # deletion first.
  defp load_items(socket) do
    actor = socket.assigns.actor

    pages = Enum.map(CMS.list_trashed_pages!(actor: actor), &{:page, &1})
    posts = Enum.map(CMS.list_trashed_posts!(actor: actor), &{:post, &1})

    items = Enum.sort_by(pages ++ posts, fn {_kind, r} -> r.archived_at end, {:desc, DateTime})
    assign(socket, :items, items)
  end

  @impl true
  def handle_event("restore", %{"kind" => kind, "id" => id}, socket) do
    actor = socket.assigns.actor

    case find_item(socket.assigns.items, kind, id) do
      nil ->
        {:noreply, socket}

      record ->
        case do_restore(kind, record, actor) do
          {:ok, _} ->
            {:noreply, socket |> load_items() |> put_flash(:info, "Restored.")}

          _ ->
            {:noreply, put_flash(socket, :error, "Couldn't restore that item.")}
        end
    end
  end

  defp find_item(items, kind, id) do
    Enum.find_value(items, fn {k, r} ->
      if to_string(k) == kind and r.id == id, do: r
    end)
  end

  defp do_restore("page", r, a), do: CMS.restore_page(r, %{}, actor: a)
  defp do_restore("post", r, a), do: CMS.restore_post(r, %{}, actor: a)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <div>
            <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
              &larr; All content
            </.link>
            <h1 class="mt-1 text-2xl font-semibold">Trash</h1>
            <p class="text-sm text-base-content/60">
              Soft-deleted content. Restore brings it back to where it was.
            </p>
          </div>
        </div>

        <p :if={@items == []} class="text-sm text-base-content/60">
          Trash is empty.
        </p>

        <ul
          :if={@items != []}
          class="divide-y divide-base-content/10 rounded border border-base-content/10"
        >
          <li
            :for={{kind, record} <- @items}
            id={"trash-#{kind}-#{record.id}"}
            class="flex items-center gap-4 p-3"
          >
            <span class="w-12 shrink-0 text-xs uppercase text-base-content/40">{kind}</span>
            <div class="min-w-0 flex-1">
              <span class="font-medium">{record.title}</span>
              <p class="truncate text-xs text-base-content/50">/{record.slug}</p>
            </div>
            <span class="text-xs text-base-content/50">
              deleted {Calendar.strftime(record.archived_at, "%Y-%m-%d %H:%M")}
            </span>
            <button
              type="button"
              phx-click="restore"
              phx-value-kind={kind}
              phx-value-id={record.id}
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
            >
              Restore
            </button>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
