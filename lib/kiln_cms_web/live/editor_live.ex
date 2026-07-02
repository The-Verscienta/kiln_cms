defmodule KilnCMSWeb.EditorLive do
  @moduledoc """
  Content list / editor home (`/editor`) — browse pages and posts with their
  workflow state, create new content, jump into the block editor, and
  publish/unpublish inline, with status + title filtering. Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes

  @statuses ~w(all draft in_review published archived)

  # Bound the per-type rows loaded into the index so a large library can't grow
  # one LiveView's heap without limit (filtering/search is client-side over this
  # window). Most-recently-updated first.
  @max_per_type 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:page_title, gettext("Content"))
     |> assign(:content_types, ContentTypes.all())
     |> assign(:statuses, @statuses)
     |> assign(:status, "all")
     |> assign(:query, "")
     |> assign(:selected, MapSet.new())
     |> assign(:confirming_bulk, nil)
     |> assign(:max_per_type, @max_per_type)
     |> load_items()}
  end

  # Only what the list renders — without a select, every row drags its whole
  # blocks JSONB tree (plus search_text and embedding) into the LiveView heap.
  # Workflow/destroy actions re-fetch the full record by id before acting.
  @list_fields [:id, :title, :slug, :state, :updated_at]

  # Records of every content type merged into `{kind, record}` tuples, newest
  # first. `truncated?` flags any type that filled its window, so the UI can say
  # older items exist instead of letting them silently vanish (audit U-M2).
  defp load_items(socket) do
    actor = socket.assigns.actor

    per_type =
      Enum.map(ContentTypes.all(), fn ct ->
        records =
          ContentTypes.list!(ct.type,
            actor: actor,
            query: [select: @list_fields, sort: [updated_at: :desc], limit: @max_per_type]
          )

        {ct.type, records}
      end)

    items =
      per_type
      |> Enum.flat_map(fn {kind, records} -> Enum.map(records, &{kind, &1}) end)
      |> Enum.sort_by(fn {_kind, r} -> r.updated_at end, {:desc, DateTime})

    socket
    |> assign(:items, items)
    |> assign(
      :truncated?,
      Enum.any?(per_type, fn {_kind, records} -> length(records) >= @max_per_type end)
    )
  end

  defp visible_items(items, status, query) do
    q = String.downcase(query)

    Enum.filter(items, fn {_kind, r} ->
      (status == "all" or to_string(r.state) == status) and
        (q == "" or String.contains?(String.downcase(r.title), q))
    end)
  end

  @impl true
  def handle_event("new", %{"kind" => kind}, socket) do
    attrs = %{
      title: "Untitled #{kind}",
      slug: "untitled-#{System.unique_integer([:positive])}"
    }

    record = create!(kind, attrs, socket.assigns.actor)
    {:noreply, push_navigate(socket, to: edit_path(kind, record.id))}
  end

  def handle_event("filter", %{"status" => status}, socket),
    do: {:noreply, assign(socket, :status, status)}

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, :query, q)}

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

  defp transition(socket, %{"kind" => kind, "id" => id}, verb) do
    actor = socket.assigns.actor
    record = get!(kind, id, actor)

    case do_transition(kind, verb, record, actor) do
      {:ok, _} -> socket |> load_items() |> put_flash(:info, gettext("Updated."))
      _ -> put_flash(socket, :error, gettext("That action isn't allowed right now."))
    end
  end

  defp create!(kind, attrs, actor), do: ContentTypes.create!(kind, attrs, actor: actor)

  defp get!(kind, id, actor), do: ContentTypes.get_record!(kind, id, actor: actor)

  defp do_transition(kind, verb, record, actor),
    do: ContentTypes.transition(kind, verb, record, actor: actor)

  # Hard delete (soft via archival). Admin-only; the policy rejects others, in
  # which case the item is counted as skipped.
  defp destroy(kind, id, actor),
    do: ContentTypes.destroy(kind, get!(kind, id, actor), actor: actor)

  # The set of selection keys ("kind:id") for the items currently visible under
  # the active status/title filter.
  defp visible_keys(socket) do
    socket.assigns.items
    |> visible_items(socket.assigns.status, socket.assigns.query)
    |> MapSet.new(fn {kind, r} -> "#{kind}:#{r.id}" end)
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
    visible = visible_items(assigns.items, assigns.status, assigns.query)
    visible_keys = MapSet.new(visible, fn {kind, r} -> "#{kind}:#{r.id}" end)

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:selected_count, MapSet.size(assigns.selected))
      |> assign(
        :all_selected?,
        MapSet.size(visible_keys) > 0 and MapSet.subset?(visible_keys, assigns.selected)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <h1 class="text-2xl font-semibold">{gettext("Content")}</h1>
          <div class="flex flex-wrap items-center gap-2">
            <%!-- Media library discoverability from the editor (#156). --%>
            <.link
              navigate={~p"/media"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Media")}
            </.link>
            <.link
              navigate={~p"/editor/taxonomy"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Taxonomy")}
            </.link>
            <.link
              navigate={~p"/editor/analytics"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Analytics")}
            </.link>
            <.link
              :if={@actor.role == :admin}
              navigate={~p"/editor/webhooks"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Webhooks")}
            </.link>
            <.link
              :if={@actor.role == :admin}
              navigate={~p"/editor/trash"}
              class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              {gettext("Trash")}
            </.link>
            <.button
              :for={ct <- @content_types}
              type="button"
              phx-click="new"
              phx-value-kind={ct.type}
              variant="primary"
            >
              {gettext("New %{type}", type: String.downcase(ct.label))}
            </.button>
          </div>
        </div>

        <div :if={@items != []} class="flex flex-wrap items-center gap-3">
          <form id="content-filter" phx-change="filter">
            <label for="content-status-filter" class="sr-only">{gettext("Filter by status")}</label>
            <select
              id="content-status-filter"
              name="status"
              aria-label={gettext("Filter by status")}
              class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
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
              class="w-full max-w-xs rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
            />
          </form>
        </div>

        <div
          :if={@visible != []}
          class="flex flex-wrap items-center gap-3 rounded border border-base-content/10 bg-base-200/40 px-3 py-2"
        >
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={@all_selected?} phx-click="toggle_select_all" />
            {gettext("Select all")}
          </label>
          <span class="text-sm text-base-content/60">
            {if @selected_count > 0,
              do: gettext("%{count} selected", count: @selected_count),
              else: gettext("None selected")}
          </span>
          <div class="ml-auto flex gap-2">
            <button
              :for={{verb, label} <- bulk_actions(@actor)}
              type="button"
              phx-click="bulk"
              phx-value-action={verb}
              disabled={@selected_count == 0}
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {label}
            </button>
            <button
              :if={@actor.role == :admin}
              type="button"
              phx-click="bulk"
              phx-value-action="delete"
              disabled={@selected_count == 0}
              class="rounded border border-error/40 px-3 py-1 text-xs text-error hover:bg-error/10 disabled:cursor-not-allowed disabled:opacity-40"
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
          <div class="ml-auto flex gap-2">
            <button
              type="button"
              phx-click="confirm_bulk"
              class={[
                "rounded px-3 py-1 text-xs font-medium hover:opacity-90",
                (@confirming_bulk == "delete" && "bg-error text-error-content") ||
                  "bg-warning text-warning-content"
              ]}
            >
              {bulk_verb_label(@confirming_bulk)}
            </button>
            <button
              type="button"
              phx-click="cancel_bulk"
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200"
            >
              {gettext("Cancel")}
            </button>
          </div>
        </div>

        <p :if={@truncated?} class="text-xs text-base-content/60" role="status">
          {gettext(
            "Showing the newest %{max} items per content type — older items exist but aren't listed here.",
            max: @max_per_type
          )}
        </p>

        <.empty_state :if={@items == []} icon="hero-document-text" title={gettext("No content yet")}>
          {gettext("Create your first page or post to get started.")}
        </.empty_state>
        <p :if={@items != [] and @visible == []} class="text-sm text-base-content/60">
          {gettext("Nothing matches the current filter.")}
        </p>

        <ul
          :if={@visible != []}
          class="divide-y divide-base-content/10 rounded border border-base-content/10"
        >
          <li
            :for={{kind, record} <- @visible}
            id={"#{kind}-#{record.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-2 p-3"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@selected, "#{kind}:#{record.id}")}
              phx-click="toggle_select"
              phx-value-key={"#{kind}:#{record.id}"}
              aria-label={gettext("Select %{title}", title: record.title)}
              class="size-4 shrink-0 rounded border border-base-content/30 accent-primary"
            />
            <span class="shrink-0 text-xs uppercase text-base-content/70">{kind}</span>
            <div class="min-w-0 flex-1">
              <.link navigate={edit_path(kind, record.id)} class="font-medium hover:underline">
                {record.title}
              </.link>
              <p class="truncate text-xs text-base-content/70">/{record.slug}</p>
            </div>
            <.state_badge state={record.state} />
            <div class="flex w-full items-center justify-end gap-2 sm:w-auto">
              <button
                :if={record.state == :draft and @actor.role == :editor}
                type="button"
                phx-click="submit"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Submit")}
              </button>
              <button
                :if={record.state in [:draft, :in_review] and @actor.role == :admin}
                type="button"
                phx-click="publish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {if record.state == :in_review, do: gettext("Approve"), else: gettext("Publish")}
              </button>
              <button
                :if={record.state == :in_review and @actor.role == :admin}
                type="button"
                phx-click="return"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Return")}
              </button>
              <button
                :if={record.state == :published}
                type="button"
                phx-click="unpublish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Unpublish")}
              </button>
              <button
                :if={record.state == :archived}
                type="button"
                phx-click="unarchive"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Unarchive")}
              </button>
              <.link
                navigate={edit_path(kind, record.id)}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Edit")}
              </.link>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
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
