defmodule KilnCMSWeb.TrashLive do
  @moduledoc """
  Trash (`/editor/trash`) — browse soft-deleted pages/posts (AshArchival sets
  `archived_at` on delete) and restore them. Admin-only, mirroring the
  destroy/restore policy on the resources.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS.ContentTypes

  @retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  # Server-side page size: each page pulls at most this many trashed rows per
  # content type (most-recently-deleted first) and keeps the merged newest
  # @page_size, so any trashed item is reachable via Load more (audit U-M2).
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Trash"))
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

  # (Re)load the first page of soft-deleted records.
  defp load_items(socket) do
    {items, more?} = fetch_page(socket, nil)

    socket
    |> assign(:items, items)
    |> assign(:more?, more?)
  end

  # One page of trashed `{kind, record}` tuples merged across every content
  # type, newest deletion first, from `cursor` (exclusive) downwards. Keeping
  # the merged newest @page_size is exact: the true next page can't contain
  # more than @page_size rows of any single type.
  defp fetch_page(socket, cursor) do
    actor = socket.assigns.actor
    query = page_query(cursor)

    per_type =
      Enum.map(editable_types(), fn ct ->
        # Dispatch on the descriptor itself so a type archived between listing
        # and dispatch can't turn into a registry-lookup miss.
        ct
        |> ContentTypes.list_trashed!(actor: actor, query: query)
        |> Enum.map(&{ct.type, &1})
      end)

    merged =
      per_type
      |> List.flatten()
      |> Enum.sort_by(fn {_kind, r} -> r.archived_at end, {:desc, DateTime})

    {page, rest} = Enum.split(merged, @page_size)

    {page, rest != [] or Enum.any?(per_type, &(length(&1) >= @page_size))}
  end

  defp page_query(cursor) do
    if(cursor, do: [{:filter, expr(archived_at < ^cursor)}], else: []) ++
      [select: @list_fields, sort: [archived_at: :desc], limit: @page_size]
  end

  defp editable_types, do: ContentTypes.all() ++ ContentTypes.dynamic_all()

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

    # Everything in the trash, not just the loaded page — walk each type in
    # bounded batches so a huge trash never materializes in memory at once.
    {ok, skipped} =
      Enum.reduce(editable_types(), {0, 0}, fn ct, acc ->
        purge_all(ct, actor, acc, nil)
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

  def handle_event("load_more", _params, socket) do
    case List.last(socket.assigns.items) do
      nil ->
        {:noreply, assign(socket, :more?, false)}

      {_kind, last} ->
        {page, more?} = fetch_page(socket, last.archived_at)

        {:noreply,
         socket
         |> assign(:items, socket.assigns.items ++ page)
         |> assign(:more?, more?)}
    end
  end

  defp do_purge(kind, record, actor), do: ContentTypes.purge(kind, record, actor: actor)

  # Purge one type's trash in @page_size batches, walking oldest-first behind
  # an archived_at cursor so rows whose purge failed are never refetched (and
  # never loop). Totals are {purged, skipped}.
  defp purge_all(ct, actor, {ok, skipped}, cursor) do
    query =
      if(cursor, do: [{:filter, expr(archived_at > ^cursor)}], else: []) ++
        [select: @list_fields, sort: [archived_at: :asc], limit: @page_size]

    batch = ContentTypes.list_trashed!(ct, actor: actor, query: query)

    totals =
      Enum.reduce(batch, {ok, skipped}, fn record, {o, s} ->
        case ContentTypes.purge(ct, record, actor: actor) do
          :ok -> {o + 1, s}
          _ -> {o, s + 1}
        end
      end)

    case batch do
      [] -> totals
      _ when length(batch) < @page_size -> totals
      _ -> purge_all(ct, actor, totals, List.last(batch).archived_at)
    end
  end

  defp find_item(items, kind, id) do
    Enum.find_value(items, fn {k, r} ->
      if to_string(k) == kind and r.id == id, do: r
    end)
  end

  defp do_restore(kind, record, actor), do: ContentTypes.restore(kind, record, actor: actor)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:trash}
    >
      <:actions>
        <.button
          :if={@items != []}
          type="button"
          phx-click="request_empty"
          variant="danger"
          size="sm"
        >
          {gettext("Empty trash")}
        </.button>
      </:actions>

      <div class="space-y-6">
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
              class="btn btn-sm bg-error text-error-content border-transparent hover:opacity-90"
            >
              {gettext("Delete everything")}
            </button>
            <button type="button" phx-click="cancel_empty" class="btn btn-sm btn-default">
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <p :if={@items == []} class="text-sm text-base-content/60">
          {gettext("Trash is empty.")}
        </p>

        <ul
          :if={@items != []}
          class="card divide-y divide-base-content/10 overflow-hidden"
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
              {gettext("deleted")}
              <time
                id={"trash-time-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.archived_at)}
              >{Calendar.strftime(record.archived_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <button
              type="button"
              phx-click="restore"
              phx-value-kind={kind}
              phx-value-id={record.id}
              class="btn btn-sm btn-default"
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
              class="btn btn-sm btn-danger"
            >
              {gettext("Delete permanently")}
            </button>
          </li>
        </ul>

        <div :if={@more?} class="flex justify-center">
          <button
            type="button"
            phx-click="load_more"
            phx-disable-with={gettext("Loading…")}
            class="btn btn-default"
          >
            {gettext("Load more")}
          </button>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
