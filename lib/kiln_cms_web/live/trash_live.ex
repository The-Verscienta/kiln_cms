defmodule KilnCMSWeb.TrashLive do
  @moduledoc """
  Trash (`/editor/trash`) — browse soft-deleted pages/posts (AshArchival sets
  `archived_at` on delete) and restore them. Admin-only, mirroring the
  destroy/restore policy on the resources.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes

  @retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  # Bound the trashed rows loaded per content type (most-recently-deleted first)
  # so a large trash can't grow the LiveView heap without limit.
  @max_per_type 500

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
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # redirects non-admins with this flash before mount runs; mirror it here so
      # this fallback stays consistent rather than silently bouncing to /editor.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # Display fields plus what restore/purge's after-action hooks read (slug,
  # locale, state for cache busting / artifact cleanup) — never the heavy
  # blocks/search_text/embedding columns the trash list doesn't show.
  @list_fields [:id, :title, :slug, :locale, :state, :archived_at, :updated_at]

  # Soft-deleted records across every content type, merged into `{kind, record}`
  # tuples, newest deletion first.
  defp load_items(socket) do
    actor = socket.assigns.actor

    items =
      ContentTypes.all()
      |> Enum.flat_map(fn ct ->
        ct.type
        |> ContentTypes.list_trashed!(
          actor: actor,
          query: [select: @list_fields, sort: [archived_at: :desc], limit: @max_per_type]
        )
        |> Enum.map(&{ct.type, &1})
      end)
      |> Enum.sort_by(fn {_kind, r} -> r.archived_at end, {:desc, DateTime})

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
            {:noreply, socket |> load_items() |> put_flash(:info, gettext("Restored."))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't restore that item."))}
        end
    end
  end

  # Permanently delete a single trashed item (#167). Guarded by a data-confirm on
  # the button; the destroy itself is admin-only at the resource policy.
  def handle_event("purge", %{"kind" => kind, "id" => id}, socket) do
    actor = socket.assigns.actor

    case find_item(socket.assigns.items, kind, id) do
      nil ->
        {:noreply, socket}

      record ->
        case do_purge(kind, record, actor) do
          :ok ->
            {:noreply,
             socket |> load_items() |> put_flash(:info, gettext("Permanently deleted."))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't delete that item."))}
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

    flash =
      if skipped > 0,
        do:
          gettext("Permanently deleted %{count}, %{skipped} skipped", count: ok, skipped: skipped),
        else: gettext("Permanently deleted %{count}", count: ok)

    {:noreply,
     socket
     |> load_items()
     |> assign(:confirming_empty, false)
     |> put_flash(:info, flash)}
  end

  defp do_purge(kind, record, actor), do: ContentTypes.purge(kind, record, actor: actor)

  defp find_item(items, kind, id) do
    Enum.find_value(items, fn {k, r} ->
      if to_string(k) == kind and r.id == id, do: r
    end)
  end

  defp do_restore(kind, record, actor), do: ContentTypes.restore(kind, record, actor: actor)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
          <div>
            <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
              &larr; {gettext("All content")}
            </.link>
            <h1 class="mt-1 text-2xl font-semibold">{gettext("Trash")}</h1>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Soft-deleted content. Restore brings it back to where it was. Trash is purged automatically after %{days} days.",
                days: @retention_days
              )}
            </p>
          </div>
          <button
            :if={@items != []}
            type="button"
            phx-click="request_empty"
            class="rounded border border-error/40 px-3 py-1.5 text-sm text-error hover:bg-error/10"
          >
            {gettext("Empty trash")}
          </button>
        </div>

        <div
          :if={@confirming_empty}
          class="flex flex-wrap items-center gap-3 rounded border border-error/40 bg-error/10 px-3 py-2 text-sm"
        >
          <span>
            {gettext("Permanently delete everything in the trash? This can't be undone.")}
          </span>
          <div class="ml-auto flex gap-2">
            <button
              type="button"
              phx-click="confirm_empty"
              class="rounded bg-error px-3 py-1 text-xs font-medium text-error-content hover:opacity-90"
            >
              {gettext("Delete everything")}
            </button>
            <button
              type="button"
              phx-click="cancel_empty"
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
            >
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <p :if={@items == []} class="text-sm text-base-content/60">
          {gettext("Trash is empty.")}
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
            <span class="w-12 shrink-0 text-xs uppercase text-base-content/70">{kind}</span>
            <div class="min-w-0 flex-1">
              <span class="font-medium">{record.title}</span>
              <p class="truncate text-xs text-base-content/70">/{record.slug}</p>
            </div>
            <span class="text-xs text-base-content/70">
              {gettext("deleted %{at}", at: Calendar.strftime(record.archived_at, "%Y-%m-%d %H:%M"))}
            </span>
            <button
              type="button"
              phx-click="restore"
              phx-value-kind={kind}
              phx-value-id={record.id}
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
            >
              {gettext("Restore")}
            </button>
            <button
              type="button"
              phx-click="purge"
              phx-value-kind={kind}
              phx-value-id={record.id}
              data-confirm={
                gettext("Permanently delete “%{title}”? This can't be undone.", title: record.title)
              }
              class="rounded border border-error/30 px-3 py-1 text-xs text-error hover:bg-error/10"
            >
              {gettext("Delete permanently")}
            </button>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
