defmodule KilnCMSWeb.TrashLive do
  @moduledoc """
  Trash (`/editor/trash`) — browse soft-deleted pages/posts (AshArchival sets
  `archived_at` on delete) and restore them. Admin-only, mirroring the
  destroy/restore policy on the resources.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  alias Ash.Error.Changes.StaleRecord
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Errors.TargetStillConnected

  @retention_days Application.compile_env(:kiln_cms, [:trash, :retention_days], 30)

  # Server-side page size: each page pulls at most this many trashed rows per
  # content type (most-recently-deleted first) and keeps the merged newest
  # @page_size, so any trashed item is reachable via Load more (audit U-M2).
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, gettext("Trash"))
     |> assign(:confirming_empty, false)
     |> assign(:retention_days, @retention_days)
     |> load_items()}
  end

  # Display fields plus what restore/purge's after-action hooks read (slug,
  # locale, state for cache busting / artifact cleanup) — never the heavy
  # blocks/search_text/embedding columns the trash list doesn't show.
  # `:org_id` is not decoration: every hook on `:restore` needs it. It reached
  # `Cache.key/5` as `%Ash.NotLoaded{}` and raised inside `BustContentCache`'s
  # `after_action`, so the transaction rolled back and Restore in this very
  # LiveView simply failed — before #1025 gave the action a second consumer of
  # the same attribute (`FireArtifacts` puts it in the Oban args). Restore and
  # purge now act on the full row (`current/4`, #2531); this projection still
  # feeds the list and the `can_*?` checks that run before them.
  @list_fields [
    :id,
    :org_id,
    :title,
    :slug,
    :locale,
    :state,
    :archived_at,
    :updated_at
  ]

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

    org = socket.assigns.current_org

    per_type =
      Enum.map(editable_types(org.id), fn ct ->
        # Dispatch on the descriptor itself so a type archived between listing
        # and dispatch can't turn into a registry-lookup miss. Scoped to the
        # editor's current site (epic #336).
        ct
        |> ContentTypes.list_trashed!(actor: actor, tenant: org, query: query)
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

  defp editable_types(org_id), do: ContentTypes.all_for_org(org_id)

  @impl true
  def handle_event("restore", %{"kind" => kind, "id" => id}, socket)
      when is_binary(kind) and is_binary(id) do
    case find_item(socket.assigns.items, kind, id) do
      nil -> {:noreply, socket}
      record -> {:noreply, restore(socket, kind, record)}
    end
  end

  # Permanently delete a single trashed item (#167). Guarded by a data-confirm on
  # the button; the destroy itself is admin-only at the resource policy.
  def handle_event("purge", %{"kind" => kind, "id" => id}, socket)
      when is_binary(kind) and is_binary(id) do
    case find_item(socket.assigns.items, kind, id) do
      nil -> {:noreply, socket}
      record -> {:noreply, purge(socket, kind, record)}
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
    org = socket.assigns.current_org

    # Everything in the trash, not just the loaded page — walk each type in
    # bounded batches so a huge trash never materializes in memory at once.
    # Scoped to the editor's current site (epic #336) so emptying one site's
    # trash never purges another's.
    {ok, skipped, held} =
      Enum.reduce(editable_types(org.id), {0, 0, 0}, fn ct, acc ->
        purge_all(ct, actor, org, acc, nil)
      end)

    flash =
      cond do
        held > 0 ->
          gettext(
            "Permanently deleted %{count}, %{skipped} skipped. %{held} are still linked from other content through a field that doesn't allow deleting them — they stay in the trash.",
            count: ok,
            skipped: skipped + held,
            held: held
          )

        skipped > 0 ->
          gettext("Permanently deleted %{count}, %{skipped} skipped", count: ok, skipped: skipped)

        true ->
          gettext("Permanently deleted %{count}", count: ok)
      end

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

  # The purge runs on the row as it is now, read in full: the list holds a
  # narrow projection (`@list_fields`), and Ash loads the missing columns
  # before a destroy — which raises for a row someone purged meanwhile
  # (#2531). The policy is asked first, so a refused editor gets the generic
  # message rather than a trash read filtered to nothing reading as "gone".
  defp purge(socket, kind, record) do
    %{actor: actor, current_org: org} = socket.assigns
    failed = gettext("Couldn't delete that item.")

    with true <- ContentTypes.can_purge?(kind, record, actor, tenant: org),
         %{} = row <- current(kind, record, actor, org),
         :ok <- ContentTypes.purge(kind, row, actor: actor, tenant: org) do
      socket |> load_items() |> put_flash(:info, gettext("Permanently deleted."))
    else
      false ->
        put_flash(socket, :error, failed)

      nil ->
        stale(socket, kind, record, failed)

      {:error, error} ->
        if stale?(error),
          do: stale(socket, kind, record, failed),
          else: put_flash(socket, :error, purge_error(error, record))
    end
  end

  # `record`'s row in full while it is still in the trash, else `nil`.
  defp current(kind, record, actor, org) do
    kind
    |> ContentTypes.list_trashed!(actor: actor, tenant: org, query: [filter: [id: record.id]])
    |> List.first()
  end

  # Purge one type's trash in @page_size batches, walking oldest-first behind
  # an archived_at cursor so rows whose purge failed are never refetched (and
  # never loop). Totals are {purged, skipped}. Every read/purge is scoped to
  # `org` (epic #336). Full rows, not `@list_fields`: a row someone purged
  # mid-walk must come back as a `StaleRecord`, and a narrow one makes Ash
  # load the rest first, which raises for a row that is gone (#2531).
  defp purge_all(ct, actor, org, {ok, skipped, held}, cursor) do
    query =
      if(cursor, do: [{:filter, expr(archived_at > ^cursor)}], else: []) ++
        [sort: [archived_at: :asc], limit: @page_size]

    batch = ContentTypes.list_trashed!(ct, actor: actor, tenant: org, query: query)

    totals =
      Enum.reduce(batch, {ok, skipped, held}, fn record, acc ->
        ct |> ContentTypes.purge(record, actor: actor, tenant: org) |> tally(acc)
      end)

    case batch do
      [] -> totals
      _ when length(batch) < @page_size -> totals
      _ -> purge_all(ct, actor, org, totals, List.last(batch).archived_at)
    end
  end

  # {purged, skipped, held}: held are the records a reference field's delete
  # rule kept (R5), counted apart so the flash can say why.
  defp tally(:ok, {ok, skipped, held}), do: {ok + 1, skipped, held}

  # A row someone else restored or purged mid-walk (#2531) left the trash on
  # its own: neither purged here nor skipped.
  defp tally({:error, error}, {ok, skipped, held}) do
    cond do
      stale?(error) -> {ok, skipped, held}
      still_connected(error) -> {ok, skipped, held + 1}
      true -> {ok, skipped + 1, held}
    end
  end

  defp tally(_other, {ok, skipped, held}), do: {ok, skipped + 1, held}

  # A field set to "Don't allow it" (`on_target_delete: :restrict`, R5) still
  # links records to this one: say so, and what to do, in the editor's words.
  defp purge_error(error, record) do
    case still_connected(error) do
      %TargetStillConnected{field_label: field, count: count} ->
        ngettext(
          "“%{title}” can't be deleted for good: 1 record still links to it through “%{field}”, which doesn't allow that. Remove the link first, or change the field's setting under Fields.",
          "“%{title}” can't be deleted for good: %{count} records still link to it through “%{field}”, which doesn't allow that. Remove the links first, or change the field's setting under Fields.",
          count,
          title: record.title || gettext("Untitled"),
          field: field
        )

      nil ->
        gettext("Couldn't delete that item.")
    end
  end

  # `:restore` and `:purge` both take only a row still in the trash (#2531),
  # so a held row someone else restored or purged since this page rendered
  # comes back as a `StaleRecord`.
  defp stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%StaleRecord{}, &1))

  defp stale?(_error), do: false

  # Which of the two it was: one read by id as the editor, which never sees
  # trashed rows — found means it is live again, not found means it is gone.
  # Either way the row leaves the list, so the next click can't fail the same
  # way. Any other read failure keeps the action's generic `failed` message.
  defp stale(socket, kind, record, failed) do
    message =
      case ContentTypes.get_record(kind, record.id,
             actor: socket.assigns.actor,
             tenant: socket.assigns.current_org
           ) do
        {:ok, _live} ->
          gettext("Someone else already restored that item.")

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
            do: gettext("That item is no longer in the trash — someone permanently deleted it."),
            else: failed

        {:error, _error} ->
          failed
      end

    socket |> load_items() |> put_flash(:error, message)
  end

  defp still_connected(%TargetStillConnected{} = error), do: error

  defp still_connected(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &still_connected/1)

  defp still_connected(_error), do: nil

  defp find_item(items, kind, id) do
    Enum.find_value(items, fn {k, r} ->
      if to_string(k) == kind and r.id == id, do: r
    end)
  end

  # On the full row, like `purge/3`: the unique-field re-check on `:restore`
  # reads the custom field values, which `@list_fields` leaves out.
  defp restore(socket, kind, record) do
    %{actor: actor, current_org: org} = socket.assigns
    failed = gettext("Couldn't restore that item.")

    with true <- ContentTypes.can_restore?(kind, record, actor, tenant: org),
         %{} = row <- current(kind, record, actor, org),
         {:ok, _} <- ContentTypes.restore(kind, row, actor: actor, tenant: org) do
      socket |> load_items() |> put_flash(:info, gettext("Restored."))
    else
      false ->
        put_flash(socket, :error, failed)

      nil ->
        stale(socket, kind, record, failed)

      {:error, error} ->
        if stale?(error),
          do: stale(socket, kind, record, failed),
          else: put_flash(socket, :error, failed)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
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
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:trash}
          />
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
              class="btn btn-sm btn-danger-fill"
            >
              {gettext("Delete everything")}
            </button>
            <button type="button" phx-click="cancel_empty" class="btn btn-sm btn-default">
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <.empty_state
          :if={@items == []}
          id="trash-empty"
          icon="hero-trash"
          title={gettext("Trash is empty.")}
        >
          {gettext("Deleted pages and posts wait here until you restore them or they are purged.")}
        </.empty_state>

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
