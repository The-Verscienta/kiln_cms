defmodule KilnCMSWeb.StructureLive do
  @moduledoc """
  The content tree for one type (#1597, decision D21) — `/editor/structure/:type`.

  The content list answers "where is that document?"; this answers "what is the
  shape of this section?". Drag to reorder within a level, indent/outdent to
  change depth, and every change writes through `:move`.

  ## One type at a time

  A parent is a record of the **same** type (`KilnCMS.CMS.ContentTree`), so a
  tree spans one type and the type is in the URL rather than a filter. A mixed
  tree would have to draw edges that cannot exist.

  ## Depth is changed with buttons, not by dragging across levels

  The same call `KilnCMSWeb.MenuLive` makes, for the same reasons and with more
  at stake: dropping *into* a sibling is a small target, ambiguous at the
  boundary between "after this" and "inside this", and unreachable from a
  keyboard. This tree decides where documents live and — with an `[ancestors]`
  alias pattern — what their URLs are, so building it without a mouse matters
  more than the gesture does. Indent means "become the child of the sibling
  directly above", which is the only placement predictable from the visual
  order, and what Drupal and WordPress both do.

  ## No filtering, no paging

  Deliberately. A filtered tree is not a tree: hiding a parent would either
  orphan its children on screen or silently promote them, and both lie about
  the structure being edited. The whole type is loaded, which is bounded by
  `KilnCMS.CMS.ContentTree.max_depth/0` in depth but not in breadth — the same
  honest limit `candidate_parents/3` carries, and the same answer if a site
  outgrows it (search-as-you-type, lazily expanded levels), rather than a
  half-measure now.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTree
  alias KilnCMS.CMS.ContentTypes

  @list_fields [:id, :title, :slug, :state, :parent_id, :position, :path_alias]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     |> assign(:max_depth, ContentTree.max_depth())}
  end

  @impl true
  def handle_params(%{"type" => type}, _uri, socket) do
    case ContentTypes.get(type, socket.assigns.current_org) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No such content type."))
         |> push_navigate(to: ~p"/editor")}

      ct ->
        {:noreply,
         socket
         |> assign(:ct, ct)
         |> assign(:page_title, gettext("Structure: %{type}", type: ct.label))
         |> load_tree()}
    end
  end

  # Drag reorders one level: renumber it from the dropped order.
  #
  # Ids from another level are ignored rather than trusted — the hook reports
  # the list it belongs to, but the payload is client-supplied, and a `position`
  # written against the wrong parent would reorder a level nobody dragged.
  @impl true
  def handle_event("reorder_items", %{"parent_id" => parent_id, "order" => order}, socket)
      when is_binary(parent_id) and is_list(order) do
    parent_id = if parent_id == "", do: nil, else: parent_id
    by_id = Map.new(socket.assigns.records, &{&1.id, &1})

    failed? =
      order
      |> Enum.with_index()
      |> Enum.any?(fn {id, index} ->
        case Map.get(by_id, id) do
          %{parent_id: ^parent_id} = record ->
            match?({:error, _}, move(socket, record, %{position: index}))

          _other_level ->
            false
        end
      end)

    socket = load_tree(socket)

    # A half-renumbered level leaves duplicate positions, which reads as a drop
    # that silently did not stick.
    {:noreply,
     if(failed?,
       do: put_flash(socket, :error, gettext("Couldn't save the new order.")),
       else: socket
     )}
  end

  # Indent: become the child of the sibling directly above.
  def handle_event("indent", %{"id" => id}, socket) when is_binary(id) do
    with %{} = record <- find(socket, id),
         %{} = above <- sibling_above(socket, record) do
      apply_move(socket, record, %{parent_id: above.id, position: next_position(socket, above.id)})
    else
      _ -> {:noreply, socket}
    end
  end

  # Outdent: become the next sibling of the current parent.
  def handle_event("outdent", %{"id" => id}, socket) when is_binary(id) do
    with %{parent_id: parent_id} = record when not is_nil(parent_id) <- find(socket, id),
         %{} = parent <- find(socket, parent_id) do
      apply_move(socket, record, %{
        parent_id: parent.parent_id,
        position: next_position(socket, parent.parent_id)
      })
    else
      _ -> {:noreply, socket}
    end
  end

  defp apply_move(socket, record, attrs) do
    case move(socket, record, attrs) do
      {:ok, _moved} ->
        {:noreply, load_tree(socket)}

      {:error, error} ->
        # The reason is actionable here — "would nest deeper than N levels" is
        # the whole point of the disabled state this bypassed.
        {:noreply, socket |> load_tree() |> put_flash(:error, move_error(error))}
    end
  end

  # Re-read the full record before writing. The tree is loaded with a narrow
  # `select` (a level of this page must not drag every document's block tree
  # into the socket), and a narrow record handed to a write raises: PaperTrail
  # JSON-encodes the attributes and `Ash.NotLoaded` has no encoder. The content
  # list makes the same re-fetch before its workflow actions, for the same
  # reason.
  defp move(socket, record, attrs) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    with {:ok, full} <- ContentTypes.get_record(socket.assigns.ct, record.id, opts) do
      ContentTypes.move(socket.assigns.ct, full, attrs, opts)
    end
  end

  defp move_error(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map_join(" ", &"#{Map.get(&1, :message, "")}.")
    |> String.trim()
    |> case do
      "" -> gettext("Couldn't move that document.")
      message -> message
    end
  end

  defp find(socket, id), do: Enum.find(socket.assigns.records, &(&1.id == id))

  defp sibling_above(socket, record) do
    socket
    |> siblings(record.parent_id)
    |> Enum.take_while(&(&1.id != record.id))
    |> List.last()
  end

  defp siblings(socket, parent_id),
    do: Enum.filter(socket.assigns.records, &(&1.parent_id == parent_id))

  # One past the last child, so an indented document lands at the end of its
  # new level rather than colliding with an existing position.
  defp next_position(socket, parent_id) do
    socket
    |> siblings(parent_id)
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp load_tree(socket) do
    records =
      ContentTypes.list!(socket.assigns.ct,
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [select: @list_fields, sort: [position: :asc, title: :asc]]
      )

    socket
    |> assign(:records, records)
    |> assign(:by_parent, Enum.group_by(records, & &1.parent_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:content}
    >
      <div class="space-y-6">
        <header class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">{gettext("Structure")}</h1>
            <p class="text-sm text-base-content/60">
              {gettext("Where each %{type} sits. Drag to reorder; indent to nest.", type: @ct.label)}
            </p>
          </div>
          <.link navigate={~p"/editor?type=#{type_value(@ct)}"} class="btn btn-default">
            {gettext("Back to the list")}
          </.link>
        </header>

        <p :if={@records == []} class="text-sm text-base-content/60" role="status">
          {gettext("Nothing to arrange yet.")}
        </p>

        <.level
          :if={@records != []}
          nodes={Map.get(@by_parent, nil, [])}
          by_parent={@by_parent}
          parent_id={nil}
          depth={1}
          max_depth={@max_depth}
          ct={@ct}
        />
      </div>
    </Layouts.console>
    """
  end

  # One level: a sortable list of siblings, each with its own children below.
  # `data-parent-id` is what lets one hook serve every level — the same
  # `MenuSortable` hook the menu builder uses, which reports `{parent_id,
  # order}` rather than a bare order for exactly this reason.
  attr :nodes, :list, required: true
  attr :by_parent, :map, required: true
  attr :parent_id, :any, default: nil
  attr :depth, :integer, required: true
  attr :max_depth, :integer, required: true
  attr :ct, :map, required: true

  defp level(assigns) do
    ~H"""
    <ul
      id={"structure-level-#{@parent_id || "root"}"}
      phx-hook="MenuSortable"
      data-parent-id={@parent_id}
      class={["space-y-2", @depth > 1 && "ml-6 mt-2 border-l border-base-content/10 pl-4"]}
    >
      <li :for={node <- @nodes} data-sort-id={node.id} class="list-none">
        <div class="card flex flex-wrap items-center gap-3 p-3">
          <span
            data-drag-handle
            class="cursor-grab text-base-content/40 active:cursor-grabbing"
            aria-hidden="true"
          >
            <.icon name="hero-bars-2" class="size-4" />
          </span>

          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{node.title}</p>
            <p class="truncate font-mono text-xs text-base-content/60">
              {node.path_alias || "/#{node.slug}"}
            </p>
          </div>

          <div class="flex items-center gap-1">
            <button
              type="button"
              phx-click="indent"
              phx-value-id={node.id}
              disabled={@depth >= @max_depth or node.id == first_id(@nodes)}
              aria-label={gettext("Indent")}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-arrow-right" class="size-4" />
            </button>
            <button
              :if={@parent_id}
              type="button"
              phx-click="outdent"
              phx-value-id={node.id}
              aria-label={gettext("Outdent")}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </button>
            <.link
              navigate={~p"/editor/content/#{type_value(@ct)}/#{node.id}"}
              class="btn btn-sm btn-default"
            >
              {gettext("Edit")}
            </.link>
          </div>
        </div>

        <.level
          :if={Map.get(@by_parent, node.id, []) != []}
          nodes={Map.get(@by_parent, node.id, [])}
          by_parent={@by_parent}
          parent_id={node.id}
          depth={@depth + 1}
          max_depth={@max_depth}
          ct={@ct}
        />
      </li>
    </ul>
    """
  end

  # The first sibling has nothing above it to become a child of.
  defp first_id([%{id: id} | _rest]), do: id
  defp first_id(_nodes), do: nil

  defp type_value(%{source: :dynamic, name: name}), do: name
  defp type_value(%{type: type}), do: to_string(type)
end
