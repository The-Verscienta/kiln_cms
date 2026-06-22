defmodule KilnCMSWeb.TrashLive do
  @moduledoc """
  Trash (`/editor/trash`) — browse soft-deleted pages/posts (AshArchival sets
  `archived_at` on delete) and restore them. Admin-only, mirroring the
  destroy/restore policy on the resources.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:confirming_empty, false)
       |> assign(:retention_days, @retention_days)
       |> load_items()}
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

  # Emptying the trash permanently deletes everything in it, so it goes through
  # a two-step confirmation rather than a single click.
  def handle_event("request_empty", _params, socket) do
    {:noreply, assign(socket, :confirming_empty, socket.assigns.items != [])}
  end

  def handle_event("cancel_empty", _params, socket),
    do: {:noreply, assign(socket, :confirming_empty, false)}

  def handle_event("confirm_empty", _params, socket) do
    actor = socket.assigns.actor

    {ok, skipped} =
      Enum.reduce(socket.assigns.items, {0, 0}, fn {kind, record}, {ok, skipped} ->
        case do_purge(to_string(kind), record, actor) do
          :ok -> {ok + 1, skipped}
          _ -> {ok, skipped + 1}
        end
      end)

    flash = "Permanently deleted #{ok}" <> if(skipped > 0, do: ", #{skipped} skipped", else: "")

    {:noreply,
     socket
     |> load_items()
     |> assign(:confirming_empty, false)
     |> put_flash(:info, flash)}
  end

  defp do_purge("page", r, a), do: CMS.purge_page(r, actor: a)
  defp do_purge("post", r, a), do: CMS.purge_post(r, actor: a)

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
              Trash is purged automatically after {@retention_days} days.
            </p>
          </div>
          <button
            :if={@items != []}
            type="button"
            phx-click="request_empty"
            class="rounded border border-error/40 px-3 py-1.5 text-sm text-error hover:bg-error/10"
          >
            Empty trash
          </button>
        </div>

        <div
          :if={@confirming_empty}
          class="flex flex-wrap items-center gap-3 rounded border border-error/40 bg-error/10 px-3 py-2 text-sm"
        >
          <span>
            Permanently delete everything in the trash? This can't be undone.
          </span>
          <div class="ml-auto flex gap-2">
            <button
              type="button"
              phx-click="confirm_empty"
              class="rounded bg-error px-3 py-1 text-xs font-medium text-error-content hover:opacity-90"
            >
              Delete everything
            </button>
            <button
              type="button"
              phx-click="cancel_empty"
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
            >
              Cancel
            </button>
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
