defmodule KilnCMSWeb.EditorLive do
  @moduledoc """
  Content list / editor home (`/editor`) — browse pages and posts with their
  workflow state, create new content, jump into the block editor, and
  publish/unpublish inline, with status + title filtering. Editor/admin only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @statuses ~w(all draft in_review published archived)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:statuses, @statuses)
     |> assign(:status, "all")
     |> assign(:query, "")
     |> assign(:selected, MapSet.new())
     |> load_items()}
  end

  # Pages and posts merged into `{kind, record}` tuples, newest first.
  defp load_items(socket) do
    actor = socket.assigns.actor

    pages = Enum.map(CMS.list_pages!(actor: actor), &{:page, &1})
    posts = Enum.map(CMS.list_posts!(actor: actor), &{:post, &1})

    items = Enum.sort_by(pages ++ posts, fn {_kind, r} -> r.updated_at end, {:desc, DateTime})
    assign(socket, :items, items)
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
    {:noreply, push_navigate(socket, to: edit_path(kind_atom(kind), record.id))}
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
    all_selected? = keys != MapSet.new() and MapSet.subset?(keys, socket.assigns.selected)

    selected =
      if all_selected?,
        do: MapSet.difference(socket.assigns.selected, keys),
        else: MapSet.union(socket.assigns.selected, keys)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("bulk", %{"action" => verb}, socket)
      when verb in ~w(publish unpublish archive) do
    actor = socket.assigns.actor

    {ok, skipped} =
      Enum.reduce(socket.assigns.selected, {0, 0}, fn key, {ok, skipped} ->
        [kind, id] = String.split(key, ":", parts: 2)

        case do_transition(kind, verb, get!(kind, id, actor), actor) do
          {:ok, _} -> {ok + 1, skipped}
          _ -> {ok, skipped + 1}
        end
      end)

    flash = "#{verb}: #{ok} updated" <> if(skipped > 0, do: ", #{skipped} skipped", else: "")

    {:noreply,
     socket |> load_items() |> assign(:selected, MapSet.new()) |> put_flash(:info, flash)}
  end

  def handle_event("publish", params, socket),
    do: {:noreply, transition(socket, params, "publish")}

  def handle_event("unpublish", params, socket),
    do: {:noreply, transition(socket, params, "unpublish")}

  defp transition(socket, %{"kind" => kind, "id" => id}, verb) do
    actor = socket.assigns.actor
    record = get!(kind, id, actor)

    case do_transition(kind, verb, record, actor) do
      {:ok, _} -> socket |> load_items() |> put_flash(:info, "Updated.")
      _ -> put_flash(socket, :error, "That action isn't allowed right now.")
    end
  end

  defp create!("page", attrs, actor), do: CMS.create_page!(attrs, actor: actor)
  defp create!("post", attrs, actor), do: CMS.create_post!(attrs, actor: actor)

  defp get!("page", id, actor), do: CMS.get_page!(id, actor: actor)
  defp get!("post", id, actor), do: CMS.get_post!(id, actor: actor)

  defp do_transition("page", "publish", r, a), do: CMS.publish_page(r, %{}, actor: a)
  defp do_transition("post", "publish", r, a), do: CMS.publish_post(r, %{}, actor: a)
  defp do_transition("page", "unpublish", r, a), do: CMS.unpublish_page(r, %{}, actor: a)
  defp do_transition("post", "unpublish", r, a), do: CMS.unpublish_post(r, %{}, actor: a)
  defp do_transition("page", "archive", r, a), do: CMS.archive_page(r, %{}, actor: a)
  defp do_transition("post", "archive", r, a), do: CMS.archive_post(r, %{}, actor: a)

  # The set of selection keys ("kind:id") for the items currently visible under
  # the active status/title filter.
  defp visible_keys(socket) do
    socket.assigns.items
    |> visible_items(socket.assigns.status, socket.assigns.query)
    |> MapSet.new(fn {kind, r} -> "#{kind}:#{r.id}" end)
  end

  defp kind_atom("page"), do: :page
  defp kind_atom("post"), do: :post

  defp edit_path(:page, id), do: ~p"/editor/pages/#{id}"
  defp edit_path(:post, id), do: ~p"/editor/posts/#{id}"

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
        visible_keys != MapSet.new() and MapSet.subset?(visible_keys, assigns.selected)
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <h1 class="text-2xl font-semibold">Content</h1>
          <div class="flex gap-2">
            <.button type="button" phx-click="new" phx-value-kind="page" variant="primary">
              New page
            </.button>
            <.button type="button" phx-click="new" phx-value-kind="post" variant="primary">
              New post
            </.button>
          </div>
        </div>

        <div :if={@items != []} class="flex flex-wrap items-center gap-3">
          <form id="content-filter" phx-change="filter">
            <select
              name="status"
              class="rounded border border-base-content/20 bg-transparent px-2 py-1.5 text-sm"
            >
              <option :for={status <- @statuses} value={status} selected={status == @status}>
                {status}
              </option>
            </select>
          </form>
          <form id="content-search" phx-change="search" class="flex-1">
            <input
              type="text"
              name="q"
              value={@query}
              placeholder="Search by title"
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
            Select all
          </label>
          <span class="text-sm text-base-content/60">
            {if @selected_count > 0, do: "#{@selected_count} selected", else: "None selected"}
          </span>
          <div class="ml-auto flex gap-2">
            <button
              :for={
                {verb, label} <- [
                  {"publish", "Publish"},
                  {"unpublish", "Unpublish"},
                  {"archive", "Archive"}
                ]
              }
              type="button"
              phx-click="bulk"
              phx-value-action={verb}
              disabled={@selected_count == 0}
              class="rounded border border-base-content/20 px-3 py-1 text-xs hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {label}
            </button>
          </div>
        </div>

        <p :if={@items == []} class="text-sm text-base-content/60">
          No content yet. Create your first page or post.
        </p>
        <p :if={@items != [] and @visible == []} class="text-sm text-base-content/60">
          Nothing matches the current filter.
        </p>

        <ul
          :if={@visible != []}
          class="divide-y divide-base-content/10 rounded border border-base-content/10"
        >
          <li
            :for={{kind, record} <- @visible}
            id={"#{kind}-#{record.id}"}
            class="flex items-center gap-4 p-3"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@selected, "#{kind}:#{record.id}")}
              phx-click="toggle_select"
              phx-value-key={"#{kind}:#{record.id}"}
            />
            <span class="w-12 shrink-0 text-xs uppercase text-base-content/40">{kind}</span>
            <div class="min-w-0 flex-1">
              <.link navigate={edit_path(kind, record.id)} class="font-medium hover:underline">
                {record.title}
              </.link>
              <p class="truncate text-xs text-base-content/50">/{record.slug}</p>
            </div>
            <.state_badge state={record.state} />
            <div class="flex items-center gap-2">
              <button
                :if={record.state in [:draft, :in_review]}
                type="button"
                phx-click="publish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                Publish
              </button>
              <button
                :if={record.state == :published}
                type="button"
                phx-click="unpublish"
                phx-value-kind={kind}
                phx-value-id={record.id}
                class="rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
              >
                Unpublish
              </button>
              <.link
                navigate={edit_path(kind, record.id)}
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
