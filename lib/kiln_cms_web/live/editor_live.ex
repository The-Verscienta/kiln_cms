defmodule KilnCMSWeb.EditorLive do
  @moduledoc """
  Content list / editor home (`/editor`) — browse pages and posts with their
  workflow state, create new content, jump into the block editor, and
  publish/unpublish inline, with status + title filtering. Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n

  @statuses ~w(all draft in_review published archived)

  # Server-side page size. Each page pulls at most @page_size rows per content
  # type from the DB (status/search filtered there too — audit U-M2) and keeps
  # the merged newest @page_size, so any item is reachable via Load more.
  @page_size 50

  # Past this many content types, the top bar's per-type "New …" buttons
  # collapse into a single dropdown so the header stays one row.
  @max_inline_new_buttons 3

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:page_title, gettext("Content"))
     |> assign(:content_types, editable_types())
     |> assign(:max_inline_new_buttons, @max_inline_new_buttons)
     |> assign(:statuses, @statuses)
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)}
  end

  # Only what the list renders — without a select, every row drags its whole
  # blocks JSONB tree (plus search_text and embedding) into the LiveView heap.
  # Workflow/destroy actions re-fetch the full record by id before acting.
  @list_fields [:id, :title, :slug, :state, :updated_at, :scheduled_at, :unpublish_at]

  # (Re)load the first page under the active status/search filter.
  defp load_items(socket) do
    {items, more?} = fetch_page(socket, nil)

    socket
    |> assign(:items, items)
    |> assign(:more?, more?)
    |> assign_translated()
  end

  # One page of `{kind, record}` tuples merged across every content type,
  # newest-updated first, from `cursor` (exclusive) downwards. Keeping the
  # merged newest @page_size is exact: the true next page can't contain more
  # than @page_size rows of any single type.
  defp fetch_page(socket, cursor) do
    actor = socket.assigns.actor
    query = page_query(socket.assigns.status, socket.assigns.query, cursor)

    per_type =
      Enum.map(editable_types(), fn ct ->
        # Dispatch on the descriptor itself so a type archived between listing
        # and dispatch can't turn into a registry-lookup miss.
        ct
        |> ContentTypes.list!(actor: actor, query: query)
        |> Enum.map(&{ct.type, &1})
      end)

    merged =
      per_type
      |> List.flatten()
      |> Enum.sort_by(fn {_kind, r} -> r.updated_at end, {:desc, DateTime})

    {page, rest} = Enum.split(merged, @page_size)

    # More pages exist if we dropped merged rows, or any type filled its
    # window (it may have more behind it even when everything merged fit).
    {page, rest != [] or Enum.any?(per_type, &(length(&1) >= @page_size))}
  end

  defp page_query(status, q, cursor) do
    [
      status != "all" && {:filter, [state: String.to_existing_atom(status)]},
      q != "" && {:filter, search_filter(q)},
      cursor && {:filter, expr(updated_at < ^cursor)}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Kernel.++(select: @list_fields, sort: [updated_at: :desc], limit: @page_size)
  end

  # Case-insensitive title/slug match; %, _ and \ in the input match literally.
  defp search_filter(q) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"
    expr(ilike(title, ^pattern) or ilike(slug, ^pattern))
  end

  # Everything editable here: compiled content types plus admin-defined dynamic
  # ones (D17) — the descriptors share a shape, and `ContentTypes` dispatch
  # routes dynamic kinds (name strings) to the generic entry tier.
  defp editable_types, do: ContentTypes.all() ++ ContentTypes.dynamic_all()

  @impl true
  def handle_event("new", %{"kind" => kind}, socket) do
    attrs = %{
      title: "Untitled #{kind}",
      slug: "untitled-#{System.unique_integer([:positive])}"
    }

    record = create!(kind, attrs, socket.assigns.actor, socket.assigns.current_org)
    {:noreply, push_navigate(socket, to: edit_path(kind, record.id))}
  end

  # Filter state lives in the URL (audit U-M3): refresh, back button, and
  # shared links keep the active status/search. Typing replaces the history
  # entry so a search doesn't leave one entry per debounced keystroke.
  def handle_event("filter", %{"status" => status}, socket),
    do: {:noreply, push_patch(socket, to: list_path(status, socket.assigns.query))}

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: list_path(socket.assigns.status, q), replace: true)}

  def handle_event("toggle_select", %{"key" => key}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, key),
        do: MapSet.delete(selected, key),
        else: MapSet.put(selected, key)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    keys = visible_keys(socket)
    all_selected? = MapSet.size(keys) > 0 and MapSet.subset?(keys, socket.assigns.selected)

    selected =
      if all_selected?,
        do: MapSet.difference(socket.assigns.selected, keys),
        else: MapSet.union(socket.assigns.selected, keys)

    {:noreply, assign(socket, :selected, selected)}
  end

  # Every bulk verb goes through the same two-step confirmation (audit
  # U-H3/U-M2): "Select all" can hold hundreds of items, and a single stray
  # click could otherwise publish, unpublish or archive all of them instantly.
  def handle_event("bulk", %{"action" => verb}, socket)
      when verb in ~w(publish unpublish archive unarchive delete) do
    confirming = if MapSet.size(socket.assigns.selected) > 0, do: verb
    {:noreply, assign(socket, :confirming_bulk, confirming)}
  end

  def handle_event("cancel_bulk", _params, socket),
    do: {:noreply, assign(socket, :confirming_bulk, nil)}

  def handle_event("confirm_bulk", _params, socket) do
    verb = socket.assigns.confirming_bulk
    actor = socket.assigns.actor

    {ok, skipped} =
      Enum.reduce(socket.assigns.selected, {0, 0}, fn key, {ok, skipped} ->
        [kind, id] = String.split(key, ":", parts: 2)

        result =
          if verb == "delete",
            do: destroy(kind, id, actor),
            else: do_transition(kind, verb, get!(kind, id, actor), actor)

        case result do
          :ok -> {ok + 1, skipped}
          {:ok, _} -> {ok + 1, skipped}
          _ -> {ok, skipped + 1}
        end
      end)

    {:noreply,
     socket
     |> load_items()
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)
     |> put_flash(:info, bulk_flash(verb, ok, skipped))}
  end

  def handle_event("publish", params, socket),
    do: {:noreply, transition(socket, params, "publish")}

  def handle_event("submit", params, socket),
    do: {:noreply, transition(socket, params, "submit")}

  def handle_event("return", params, socket),
    do: {:noreply, transition(socket, params, "return")}

  def handle_event("unpublish", params, socket),
    do: {:noreply, transition(socket, params, "unpublish")}

  def handle_event("unarchive", params, socket),
    do: {:noreply, transition(socket, params, "unarchive")}

  def handle_event("load_more", _params, socket) do
    case List.last(socket.assigns.items) do
      nil ->
        {:noreply, assign(socket, :more?, false)}

      {_kind, last} ->
        {page, more?} = fetch_page(socket, last.updated_at)

        {:noreply,
         socket
         |> assign(:items, socket.assigns.items ++ page)
         |> assign(:more?, more?)
         |> assign_translated()}
    end
  end

  # The "fully translated" bit of each row's status trigram: which visible
  # {kind, slug} groups have a variant in every configured locale. One
  # slug-batched query per kind on the visible page; `nil` (single-locale
  # site) means trivially covered.
  defp assign_translated(socket) do
    locales = I18n.locales()

    if length(locales) < 2 do
      assign(socket, :translated, nil)
    else
      actor = socket.assigns.actor

      translated =
        socket.assigns.items
        |> Enum.group_by(fn {kind, _r} -> kind end, fn {_kind, r} -> r.slug end)
        |> Enum.flat_map(fn {kind, slugs} -> covered_slugs(kind, slugs, locales, actor) end)
        |> MapSet.new()

      assign(socket, :translated, translated)
    end
  end

  # The {kind, slug} pairs among `slugs` whose slug group has a variant in
  # every configured locale.
  defp covered_slugs(kind, slugs, locales, actor) do
    kind
    |> ContentTypes.list!(
      actor: actor,
      query: [filter: expr(slug in ^slugs), select: [:slug, :locale]]
    )
    |> Enum.group_by(& &1.slug, & &1.locale)
    |> Enum.filter(fn {_slug, ls} -> Enum.all?(locales, &(&1 in ls)) end)
    |> Enum.map(fn {slug, _ls} -> {kind, slug} end)
  end

  defp translated?(nil, _kind, _slug), do: true
  defp translated?(set, kind, slug), do: MapSet.member?(set, {kind, slug})

  # The trigram's "scheduled" bit: a pending transition the calendar would
  # show — publish for drafts/in-review, unpublish for published.
  defp scheduled?(%{state: state} = r) when state in [:draft, :in_review],
    do: not is_nil(r.scheduled_at)

  defp scheduled?(%{state: :published} = r), do: not is_nil(r.unpublish_at)
  defp scheduled?(_record), do: false

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "all"

    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:query, params["q"] || "")
     |> load_items()}
  end

  defp list_path(status, q) do
    params =
      [status: status, q: q]
      |> Enum.reject(fn {k, v} -> v == "" or (k == :status and v == "all") end)
      |> Map.new()

    ~p"/editor?#{params}"
  end

  defp transition(socket, %{"kind" => kind, "id" => id}, verb) do
    actor = socket.assigns.actor
    record = get!(kind, id, actor)

    case do_transition(kind, verb, record, actor) do
      {:ok, _} -> socket |> load_items() |> put_flash(:info, gettext("Updated."))
      _ -> put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  # `tenant:` stamps the new record with the current site's org (epic #336);
  # `org_id` is writable? false, so the tenant is the only way to set it.
  defp create!(kind, attrs, actor, org),
    do: ContentTypes.create!(kind, attrs, actor: actor, tenant: org)

  defp get!(kind, id, actor), do: ContentTypes.get_record!(kind, id, actor: actor)

  defp do_transition(kind, verb, record, actor),
    do: ContentTypes.transition(kind, verb, record, actor: actor)

  # Hard delete (soft via archival). Admin-only; the policy rejects others, in
  # which case the item is counted as skipped.
  defp destroy(kind, id, actor),
    do: ContentTypes.destroy(kind, get!(kind, id, actor), actor: actor)

  # The set of selection keys ("kind:id") for the currently loaded items (the
  # status/search filter already ran server-side).
  defp visible_keys(socket) do
    MapSet.new(socket.assigns.items, fn {kind, r} -> "#{kind}:#{r.id}" end)
  end

  defp edit_path(type, id), do: ~p"/editor/content/#{type}/#{id}"

  defp bulk_actions(%{role: :admin}) do
    [
      {"publish", gettext("Publish")},
      {"unpublish", gettext("Unpublish")},
      {"archive", gettext("Archive")},
      {"unarchive", gettext("Unarchive")}
    ]
  end

  defp bulk_actions(_actor) do
    [
      {"unpublish", gettext("Unpublish")},
      {"archive", gettext("Archive")},
      {"unarchive", gettext("Unarchive")}
    ]
  end

  defp bulk_verb_label("publish"), do: gettext("Publish")
  defp bulk_verb_label("unpublish"), do: gettext("Unpublish")
  defp bulk_verb_label("archive"), do: gettext("Archive")
  defp bulk_verb_label("unarchive"), do: gettext("Unarchive")
  defp bulk_verb_label("delete"), do: gettext("Delete")

  # What the user is about to do, spelled out with its consequence. The delete
  # copy tells the truth about soft-delete (audit U-M1): items go to the trash,
  # restorable for 30 days — the old "This can't be undone" scared editors off
  # a recoverable action.
  defp bulk_confirm_prompt("publish", n),
    do:
      gettext("Publish %{count} selected item(s)? They go live on the site immediately.",
        count: n
      )

  defp bulk_confirm_prompt("unpublish", n),
    do:
      gettext("Unpublish %{count} selected item(s)? They come off the site and return to draft.",
        count: n
      )

  defp bulk_confirm_prompt("archive", n),
    do:
      gettext(
        "Archive %{count} selected item(s)? Archived content leaves the site; you can unarchive it later.",
        count: n
      )

  defp bulk_confirm_prompt("unarchive", n),
    do: gettext("Unarchive %{count} selected item(s)? They return to draft.", count: n)

  defp bulk_confirm_prompt("delete", n),
    do:
      gettext(
        "Move %{count} selected item(s) to trash? Admins can restore them from Trash for 30 days.",
        count: n
      )

  defp bulk_flash("delete", ok, skipped) do
    if skipped > 0,
      do:
        gettext("Moved %{count} item(s) to trash, %{skipped} skipped",
          count: ok,
          skipped: skipped
        ),
      else: gettext("Moved %{count} item(s) to trash", count: ok)
  end

  defp bulk_flash(verb, ok, skipped) do
    if skipped > 0,
      do:
        gettext("%{action}: %{count} updated, %{skipped} skipped",
          action: bulk_verb_label(verb),
          count: ok,
          skipped: skipped
        ),
      else: gettext("%{action}: %{count} updated", action: bulk_verb_label(verb), count: ok)
  end

  @impl true
  def render(assigns) do
    visible_keys = MapSet.new(assigns.items, fn {kind, r} -> "#{kind}:#{r.id}" end)

    assigns =
      assigns
      |> assign(:filtering?, assigns.status != "all" or assigns.query != "")
      |> assign(:selected_count, MapSet.size(assigns.selected))
      |> assign(
        :all_selected?,
        MapSet.size(visible_keys) > 0 and MapSet.subset?(visible_keys, assigns.selected)
      )

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={gettext("Content")}
      active={:content}
    >
      <:actions>
        <%!-- A handful of types reads best as direct buttons; past that the row
              (even wrapping) crowds out the top bar, so collapse into one menu.
              CSS-only <details>, same pattern as the mobile nav disclosure. --%>
        <.button
          :for={ct <- @content_types}
          :if={length(@content_types) <= @max_inline_new_buttons}
          type="button"
          phx-click="new"
          phx-value-kind={ct.type}
          variant="primary"
          size="sm"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("New %{type}", type: String.downcase(ct.label))}
        </.button>
        <details
          :if={length(@content_types) > @max_inline_new_buttons}
          id="content-new-menu"
          class="relative"
        >
          <summary class="btn btn-primary btn-sm cursor-pointer list-none [&::-webkit-details-marker]:hidden">
            <.icon name="hero-plus" class="size-4" />
            {gettext("New")}
            <.icon name="hero-chevron-down" class="size-3.5" />
          </summary>
          <div class="absolute right-0 z-30 mt-2 flex max-h-96 w-56 flex-col gap-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-100 p-1.5 shadow-lg">
            <button
              :for={ct <- @content_types}
              type="button"
              phx-click="new"
              phx-value-kind={ct.type}
              class="rounded-md px-2.5 py-1.5 text-left text-sm hover:bg-base-200"
            >
              {gettext("New %{type}", type: String.downcase(ct.label))}
            </button>
          </div>
        </details>
      </:actions>

      <div class="space-y-5">
        <div>
          <h1 class="text-xl font-semibold tracking-tight">{gettext("Content")}</h1>
          <p class="text-sm text-base-content/60">
            {gettext("Pages, posts and custom types across your site.")}
          </p>
        </div>

        <div :if={@items != [] or @filtering?} class="flex flex-wrap items-center gap-3">
          <form id="content-filter" phx-change="filter">
            <label for="content-status-filter" class="sr-only">{gettext("Filter by status")}</label>
            <select
              id="content-status-filter"
              name="status"
              aria-label={gettext("Filter by status")}
              class="field-select w-auto"
            >
              <option :for={status <- @statuses} value={status} selected={status == @status}>
                {status_filter_label(status)}
              </option>
            </select>
          </form>
          <form id="content-search" phx-change="search" class="flex-1">
            <label for="content-search-input" class="sr-only">{gettext("Search by title")}</label>
            <input
              id="content-search-input"
              type="text"
              name="q"
              value={@query}
              placeholder={gettext("Search by title")}
              aria-label={gettext("Search by title")}
              phx-debounce="200"
              autocomplete="off"
              class="field-input max-w-xs"
            />
          </form>
        </div>

        <div
          :if={@items != []}
          class="flex flex-wrap items-center gap-3 rounded-lg border border-base-content/10 bg-base-200/40 px-3 py-2"
        >
          <label class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={@all_selected?}
              phx-click="toggle_select_all"
              class="size-4 rounded border-base-content/30 accent-primary"
            />
            {gettext("Select all")}
          </label>
          <span class="text-sm text-base-content/60">
            {if @selected_count > 0,
              do: gettext("%{count} selected", count: @selected_count),
              else: gettext("None selected")}
          </span>
          <div class="ml-auto flex flex-wrap justify-end gap-2">
            <button
              :for={{verb, label} <- bulk_actions(@actor)}
              type="button"
              phx-click="bulk"
              phx-value-action={verb}
              disabled={@selected_count == 0}
              class="btn btn-sm btn-default"
            >
              {label}
            </button>
            <button
              :if={@actor.role == :admin}
              type="button"
              phx-click="bulk"
              phx-value-action="delete"
              disabled={@selected_count == 0}
              class="btn btn-sm btn-danger"
            >
              {gettext("Delete")}
            </button>
          </div>
        </div>

        <div
          :if={@confirming_bulk}
          class={[
            "flex flex-wrap items-center gap-3 rounded border px-3 py-2 text-sm",
            (@confirming_bulk == "delete" && "border-error/40 bg-error/10") ||
              "border-warning/40 bg-warning/10"
          ]}
        >
          <span>{bulk_confirm_prompt(@confirming_bulk, @selected_count)}</span>
          <div class="ml-auto flex flex-wrap justify-end gap-2">
            <button
              type="button"
              phx-click="confirm_bulk"
              class={[
                "btn btn-sm border-transparent hover:opacity-90",
                (@confirming_bulk == "delete" && "bg-error text-error-content") ||
                  "bg-warning text-warning-content"
              ]}
            >
              {bulk_verb_label(@confirming_bulk)}
            </button>
            <button type="button" phx-click="cancel_bulk" class="btn btn-sm btn-default">
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <.empty_state
          :if={@items == [] and not @filtering?}
          icon="hero-document-text"
          title={gettext("No content yet")}
        >
          {gettext("Create your first page or post to get started.")}
        </.empty_state>
        <p :if={@items == [] and @filtering?} class="text-sm text-base-content/60" role="status">
          {gettext("Nothing matches the current filter.")}
        </p>

        <ul
          :if={@items != []}
          class="card divide-y divide-base-content/10 overflow-hidden"
        >
          <li
            :for={{kind, record} <- @items}
            id={"#{kind}-#{record.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-2 p-3 transition-colors hover:bg-base-200/40"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@selected, "#{kind}:#{record.id}")}
              phx-click="toggle_select"
              phx-value-key={"#{kind}:#{record.id}"}
              aria-label={gettext("Select %{title}", title: record.title)}
              class="size-4 shrink-0 rounded border border-base-content/30 accent-primary"
            />
            <.content_trigram
              published={record.state == :published}
              translated={translated?(@translated, kind, record.slug)}
              scheduled={scheduled?(record)}
              class="text-base-content/50"
            />
            <span class="shrink-0 text-xs uppercase text-base-content/70">{kind}</span>
            <div class="min-w-0 flex-1">
              <.link navigate={edit_path(kind, record.id)} class="font-medium hover:underline">
                {record.title}
              </.link>
              <p class="truncate text-xs text-base-content/70">/{record.slug}</p>
            </div>
            <.state_badge state={record.state} />
            <span
              :if={record.scheduled_at && record.state in [:draft, :in_review]}
              class="flex items-center gap-1 text-xs text-base-content/60"
              title={gettext("Scheduled to publish")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              <time
                id={"scheduled-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.scheduled_at)}
              >{Calendar.strftime(record.scheduled_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <span
              :if={record.unpublish_at && record.state == :published}
              class="flex items-center gap-1 text-xs text-base-content/60"
              title={gettext("Scheduled to unpublish")}
            >
              <.icon name="hero-clock" class="size-3.5" />
              <time
                id={"unpublish-#{kind}-#{record.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(record.unpublish_at)}
              >{Calendar.strftime(record.unpublish_at, "%Y-%m-%d %H:%M")} UTC</time>
            </span>
            <div class="flex w-full items-center justify-end gap-2 sm:w-auto">
              <button
                :if={record.state == :draft and @actor.role == :editor}
                type="button"
                phx-click="submit"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Submit")}
              </button>
              <button
                :if={record.state in [:draft, :in_review] and @actor.role == :admin}
                type="button"
                phx-click="publish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {if record.state == :in_review, do: gettext("Approve"), else: gettext("Publish")}
              </button>
              <button
                :if={record.state == :in_review and @actor.role == :admin}
                type="button"
                phx-click="return"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Return")}
              </button>
              <button
                :if={record.state == :published}
                type="button"
                phx-click="unpublish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Unpublish")}
              </button>
              <button
                :if={record.state == :archived}
                type="button"
                phx-click="unarchive"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Unarchive")}
              </button>
              <.link
                navigate={edit_path(kind, record.id)}
                class="btn btn-sm btn-default"
              >
                {gettext("Edit")}
              </.link>
            </div>
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

  # Humanized, localized labels for the status-filter <select> (#155). Accepts a
  # filter value string, including the "all" pseudo-state, or a workflow-state
  # atom. The content-state badge itself uses CoreComponents.state_badge/1.
  defp status_filter_label("all"), do: gettext("All")

  defp status_filter_label(state) when is_binary(state),
    do: status_filter_label(String.to_existing_atom(state))

  defp status_filter_label(:draft), do: gettext("Draft")
  defp status_filter_label(:in_review), do: gettext("In review")
  defp status_filter_label(:published), do: gettext("Published")
  defp status_filter_label(:archived), do: gettext("Archived")

  defp status_filter_label(other) when is_atom(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
