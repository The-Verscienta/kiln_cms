defmodule KilnCMSWeb.MenuLive do
  @moduledoc """
  Editor-managed navigation menus (#466).

  `/editor/menus` lists this site's menus (one per key + locale) and creates
  new ones; `/editor/menus/:id` is the tree builder for one menu — add items,
  drag to reorder within a level, indent/outdent to change depth, and edit an
  item's label and destination.

  Depth is changed with buttons rather than by dragging across levels. Dropping
  *into* a sibling is a small target, ambiguous at the boundary between "after
  this item" and "inside it", and unreachable from a keyboard — and this tree is
  the site's navigation, so being able to build it without a mouse matters more
  than the gesture.

  Items link to content **by reference**, so the picker asks for a type and a
  slug (the same shape `/editor/redirects` uses for a manual redirect) rather
  than a URL: what gets stored is the record, and the URL is resolved live at
  delivery time by `KilnCMS.CMS.Menus`.
  """
  use KilnCMSWeb, :live_view

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.MenuItem
  alias KilnCMS.CMS.Menus
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.I18n

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:actor, socket.assigns.current_user)
     # Deleting a menu is admin-only in the resource policy; without this the
     # button is offered to editors and only fails on click.
     |> assign(:admin?, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> assign(:page_title, gettext("Menus"))
     |> assign(:new_menu, to_form(empty_menu(), as: :menu))
     |> assign(:new_item, to_form(empty_item(), as: :item))
     |> assign(:editing, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case CMS.get_menu(id, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, menu} ->
        {:noreply,
         socket
         |> assign(:live_action, :show)
         |> assign(:menu, menu)
         |> assign(:page_title, menu.name)
         |> load_items()}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That menu no longer exists."))
         |> push_navigate(to: ~p"/editor/menus")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:live_action, :index) |> assign(:menu, nil) |> load_menus()}
  end

  # --- menus -----------------------------------------------------------------

  @impl true
  def handle_event("create_menu", %{"menu" => params}, socket) when is_map(params) do
    attrs = Map.take(params, ["key", "name", "locale", "description"])

    case CMS.create_menu(attrs, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, menu} ->
        {:noreply, push_navigate(socket, to: ~p"/editor/menus/#{menu.id}")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:new_menu, to_form(params, as: :menu))
         |> put_flash(:error, error_message(error, gettext("Couldn't create that menu.")))}
    end
  end

  def handle_event("delete_menu", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, menu} <- CMS.get_menu(id, actor: actor, tenant: org),
           :ok <- CMS.destroy_menu(menu, actor: actor, tenant: org) do
        socket |> load_menus() |> put_flash(:info, gettext("Menu deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that menu."))
      end

    {:noreply, socket}
  end

  # --- items -----------------------------------------------------------------

  def handle_event("add_item", %{"item" => params}, socket) when is_map(params) do
    attrs =
      params
      |> item_attrs(socket)
      |> Map.put(:menu_id, socket.assigns.menu.id)
      # New items land at the end of the root level; indent moves them.
      |> Map.put(:position, next_position(socket, nil))

    case CMS.create_menu_item(attrs,
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _item} ->
        {:noreply, socket |> assign(:new_item, to_form(empty_item(), as: :item)) |> load_items()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:new_item, to_form(params, as: :item))
         |> put_flash(:error, error_message(error, gettext("Couldn't add that item.")))}
    end
  end

  def handle_event("edit_item", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.items, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply, assign(socket, :editing, {id, to_form(item_form(item, socket), as: :item)})}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_item", %{"item_id" => id, "item" => params}, socket)
      when is_binary(id) and is_map(params) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    with {:ok, item} <- CMS.get_menu_item(id, actor: actor, tenant: org),
         {:ok, _} <-
           CMS.update_menu_item(item, item_attrs(params, socket), actor: actor, tenant: org) do
      {:noreply, socket |> assign(:editing, nil) |> load_items()}
    else
      {:error, error} ->
        {:noreply,
         socket
         |> assign(:editing, {id, to_form(params, as: :item)})
         |> put_flash(:error, error_message(error, gettext("Couldn't save that item.")))}
    end
  end

  def handle_event("delete_item", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, item} <- CMS.get_menu_item(id, actor: actor, tenant: org),
           :ok <- CMS.destroy_menu_item(item, actor: actor, tenant: org) do
        socket |> assign(:editing, nil) |> load_items()
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that item."))
      end

    {:noreply, socket}
  end

  # Drag reorder within one level: the hook reports the level's parent and its
  # new child order, and every row in it is renumbered. Renumbering the whole
  # level (rather than the moved row alone) is what makes the result stable —
  # positions stay dense, so the next drop has no ties to break.
  def handle_event("reorder_items", %{"parent_id" => parent_id, "order" => order}, socket)
      when is_binary(parent_id) and is_list(order) do
    parent_id = if parent_id == "", do: nil, else: parent_id
    by_id = Map.new(socket.assigns.items, &{&1.id, &1})

    failed? =
      order
      |> Enum.with_index()
      |> Enum.any?(fn {id, index} ->
        case Map.get(by_id, id) do
          %{parent_id: ^parent_id} = item ->
            match?({:error, _}, update_item(socket, item, %{position: index}))

          _other_level ->
            false
        end
      end)

    socket = load_items(socket)

    # A half-renumbered level leaves duplicate positions, which read as a
    # successful drop that silently didn't stick. Say so.
    socket =
      if failed?,
        do: put_flash(socket, :error, gettext("Couldn't save the new order.")),
        else: socket

    {:noreply, socket}
  end

  # Indent: become the child of the sibling directly above. That is the only
  # placement a reader could predict from the visual order, and it is exactly
  # how Drupal and WordPress behave.
  def handle_event("indent_item", %{"id" => id}, socket) when is_binary(id) do
    with %{} = item <- Enum.find(socket.assigns.items, &(&1.id == id)),
         %{} = above <- sibling_above(socket, item) do
      case update_item(socket, item, %{
             parent_id: above.id,
             position: next_position(socket, above.id)
           }) do
        {:ok, _} -> {:noreply, load_items(socket)}
        {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error, nil))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Outdent: become the next sibling of the current parent.
  def handle_event("outdent_item", %{"id" => id}, socket) when is_binary(id) do
    with %{parent_id: parent_id} = item when not is_nil(parent_id) <-
           Enum.find(socket.assigns.items, &(&1.id == id)),
         %{} = parent <- Enum.find(socket.assigns.items, &(&1.id == parent_id)) do
      case update_item(socket, item, %{
             parent_id: parent.parent_id,
             position: next_position(socket, parent.parent_id)
           }) do
        {:ok, _} -> {:noreply, load_items(socket)}
        {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error, nil))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # --- data ------------------------------------------------------------------

  defp load_menus(socket) do
    menus = CMS.list_menus!(actor: socket.assigns.actor, tenant: socket.assigns.current_org)
    assign(socket, :menus, menus)
  end

  # The flat rows (for reordering maths) plus the resolved tree the page renders.
  # `include_hidden?: true` — this is the editor's view of the menu, so an item
  # whose target is still a draft must be visible and editable, not silently
  # missing.
  defp load_items(socket) do
    menu = socket.assigns.menu
    org = socket.assigns.current_org

    items =
      MenuItem
      |> Ash.Query.filter(menu_id == ^menu.id)
      |> Ash.Query.sort(position: :asc, label: :asc)
      |> Ash.read!(actor: socket.assigns.actor, tenant: org)

    socket
    |> assign(:items, items)
    |> assign(:tree, Menus.tree(menu, Accounts.org_id(org), include_hidden?: true))
    |> assign(:max_depth, MenuItem.max_depth())
  end

  defp update_item(socket, item, attrs) do
    CMS.update_menu_item(item, attrs,
      actor: socket.assigns.actor,
      tenant: socket.assigns.current_org
    )
  end

  defp siblings(socket, parent_id),
    do: Enum.filter(socket.assigns.items, &(&1.parent_id == parent_id))

  # `max + 1`, not `length` — indent/outdent/delete leave gaps in the source
  # level, so a count collides with a position that is still in use and the
  # label tiebreak then sorts the new item into the middle.
  defp next_position(socket, parent_id) do
    socket
    |> siblings(parent_id)
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp sibling_above(socket, item) do
    socket
    |> siblings(item.parent_id)
    |> Enum.sort_by(&{&1.position, &1.label})
    |> Enum.take_while(&(&1.id != item.id))
    |> List.last()
  end

  # Form params → create/update attrs. The content picker speaks (type, slug);
  # the reference stored is the record's id, resolved here so a typo is a form
  # error rather than a dangling menu item.
  defp item_attrs(params, socket) do
    base = %{
      label: params["label"],
      link_type: link_type(params["link_type"]),
      open_in_new_tab: params["open_in_new_tab"] == "true",
      visible: params["visible"] != "false"
    }

    case base.link_type do
      :content ->
        {type, id} = resolve_target(params, socket)
        Map.merge(base, %{target_type: type, target_id: id})

      :url ->
        Map.put(base, :url, params["url"])

      :none ->
        base
    end
  end

  defp link_type("url"), do: :url
  defp link_type("none"), do: :none
  defp link_type(_content), do: :content

  # `{type_name, id}` for the picked type + slug, or `{type, nil}` so the
  # resource's own destination validation reports the miss.
  defp resolve_target(params, socket) do
    type = params["target_type"]
    slug = params["target_slug"]

    with ct when not is_nil(ct) <-
           ContentTypes.get(type, socket.assigns.current_org),
         slug when is_binary(slug) and slug != "" <- slug && String.trim(to_string(slug)),
         %{id: id} <- fetch_target(ct, slug, socket) do
      {to_string(ct.type), id}
    else
      _ -> {type, nil}
    end
  end

  # Scoped to the **menu's** locale: a slug is unique per locale, not globally
  # (`unique [slug, locale]`), so an unscoped read raises `MultipleResults` the
  # moment a page is translated — and a French menu should reference the French
  # record anyway.
  #
  # Read as the acting user, not `authorize?: false`: an editor restricted by
  # `readable_types` must not get an existence oracle over types they can't see.
  # Any workflow state that user *can* read is fine — an item pointing at a
  # draft simply starts resolving in delivery once that draft publishes.
  defp fetch_target(ct, slug, socket) do
    locale = socket.assigns.menu.locale

    query =
      ct
      |> Slugs.storage_resource()
      |> Ash.Query.filter(slug == ^slug and locale == ^locale)
      |> Ash.Query.select([:id, :slug])
      |> Ash.Query.limit(1)

    query =
      case ct do
        %{source: :dynamic, definition: definition} ->
          Ash.Query.filter(query, type_definition_id == ^definition.id)

        _compiled ->
          query
      end

    case Ash.read_one(query, actor: socket.assigns.actor, tenant: socket.assigns.current_org) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  # An existing item projected back onto the form's shape — including the
  # target's *slug*, which the row stores only as an id.
  defp item_form(item, socket) do
    %{
      "label" => item.label,
      "link_type" => to_string(item.link_type),
      "url" => item.url,
      "target_type" => item.target_type,
      "target_slug" => target_slug(item, socket),
      "open_in_new_tab" => to_string(item.open_in_new_tab),
      "visible" => to_string(item.visible)
    }
  end

  # Tenant-scoped like every other `get_record` call: under the production
  # (strict-tenancy) build a tenant-less read errors outright, which would leave
  # the Slug field blank and make content-linked items unsavable.
  defp target_slug(%{link_type: :content, target_type: type, target_id: id}, socket)
       when is_binary(type) and is_binary(id) do
    case ContentTypes.get_record(type, id,
           actor: socket.assigns.actor,
           tenant: socket.assigns.current_org
         ) do
      {:ok, record} -> record.slug
      _ -> nil
    end
  end

  defp target_slug(_item, _socket), do: nil

  defp empty_menu,
    do: %{"key" => "", "name" => "", "locale" => I18n.default_locale(), "description" => ""}

  defp empty_item,
    do: %{"label" => "", "link_type" => "content", "target_type" => "page", "target_slug" => ""}

  # The first item in a level has no sibling above it to nest under, so Indent
  # would be a button that does nothing.
  defp first_id([%{id: id} | _rest]), do: id
  defp first_id(_empty), do: nil

  defp type_options(org), do: ContentTypes.options(org)

  defp link_type_options do
    [
      {gettext("Content"), "content"},
      {gettext("URL"), "url"},
      {gettext("Label only"), "none"}
    ]
  end

  # The first field-level message an Ash error carries, which is far more useful
  # than "couldn't save" — "would nest deeper than 3 levels" is the whole answer.
  defp error_message(%Ash.Error.Invalid{errors: errors}, fallback) do
    Enum.find_value(errors, fallback, fn
      %{message: message} when is_binary(message) -> message
      _ -> nil
    end)
  end

  defp error_message(_error, fallback), do: fallback

  # --- render ----------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:menus}
    >
      <.header>
        {gettext("Menus")}
        <:subtitle>
          {gettext(
            "Navigation your front end reads from the API. Items link to content by reference, so renaming a slug never breaks the menu. One menu per key and locale."
          )}
        </:subtitle>
      </.header>

      <div class="card card-pad mt-6">
        <h2 class="text-sm font-medium">{gettext("New menu")}</h2>
        <.form
          for={@new_menu}
          id="new-menu-form"
          phx-submit="create_menu"
          class="mt-3 grid gap-3 sm:grid-cols-4"
        >
          <.input field={@new_menu[:name]} label={gettext("Name")} placeholder="Main navigation" />
          <.input field={@new_menu[:key]} label={gettext("Key")} placeholder="main" />
          <.input
            field={@new_menu[:locale]}
            type="select"
            label={gettext("Locale")}
            options={I18n.locales()}
          />
          <div class="flex items-end">
            <.button variant="primary" size="sm">{gettext("Create menu")}</.button>
          </div>
        </.form>
      </div>

      <.empty_state :if={@menus == []} icon="hero-bars-3" title={gettext("No menus yet")}>
        {gettext("Create one, then add items pointing at your content.")}
      </.empty_state>

      <div :if={@menus != []} class="mt-6 overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Name")}</th>
              <th>{gettext("Key")}</th>
              <th>{gettext("Locale")}</th>
              <th>{gettext("API")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={menu <- @menus}>
              <td>
                <.link navigate={~p"/editor/menus/#{menu.id}"} class="link font-medium">
                  {menu.name}
                </.link>
              </td>
              <td class="font-mono text-xs">{menu.key}</td>
              <td>{menu.locale}</td>
              <td class="font-mono text-xs text-base-content/60">
                /api/menus/{menu.key}?locale={menu.locale}
              </td>
              <td class="text-right">
                <button
                  :if={@admin?}
                  type="button"
                  phx-click="delete_menu"
                  phx-value-id={menu.id}
                  data-confirm={gettext("Delete this menu and all of its items?")}
                  aria-label={gettext("Delete menu")}
                  class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:menus}
    >
      <.header>
        <.link navigate={~p"/editor/menus"} class="text-sm text-base-content/60 hover:underline">
          &larr; {gettext("All menus")}
        </.link>
        <div class="mt-1">{@menu.name}</div>
        <:subtitle>
          {gettext("Key %{key} · locale %{locale} · served at %{path}",
            key: @menu.key,
            locale: @menu.locale,
            path: "/api/menus/#{@menu.key}?locale=#{@menu.locale}"
          )}
        </:subtitle>
      </.header>

      <.empty_state :if={@tree == []} icon="hero-bars-3" title={gettext("No items yet")}>
        {gettext("Add the first link below.")}
      </.empty_state>

      <div :if={@tree != []} class="mt-6">
        {render_level(%{
          nodes: @tree,
          parent_id: nil,
          depth: 1,
          items: @items,
          editing: @editing,
          max_depth: @max_depth,
          current_org: @current_org
        })}
      </div>

      <div class="card card-pad mt-6">
        <h2 class="text-sm font-medium">{gettext("Add an item")}</h2>
        <.form
          for={@new_item}
          id="new-item-form"
          phx-submit="add_item"
          class="mt-3 grid gap-3 sm:grid-cols-5"
        >
          <.input field={@new_item[:label]} label={gettext("Label")} placeholder="About us" />
          <.input
            field={@new_item[:link_type]}
            type="select"
            label={gettext("Links to")}
            options={link_type_options()}
          />
          <.input
            field={@new_item[:target_type]}
            type="select"
            label={gettext("Content type")}
            options={type_options(@current_org)}
          />
          <.input field={@new_item[:target_slug]} label={gettext("Slug")} placeholder="about" />
          <.input field={@new_item[:url]} label={gettext("or URL")} placeholder="https://…" />
          <div class="sm:col-span-5">
            <.button variant="primary" size="sm">{gettext("Add item")}</.button>
            <span class="ml-2 text-xs text-base-content/60">
              {gettext(
                "A content item stores a reference, so its URL follows the record. Items pointing at unpublished content are omitted from the API."
              )}
            </span>
          </div>
        </.form>
      </div>
    </Layouts.console>
    """
  end

  # One level of the tree: a sortable list of siblings, each with its own
  # children rendered underneath. `data-parent-id` is what lets one hook serve
  # every level.
  defp render_level(assigns) do
    ~H"""
    <ul
      id={"menu-level-#{@parent_id || "root"}"}
      phx-hook="MenuSortable"
      data-parent-id={@parent_id}
      class={["space-y-2", @depth > 1 && "ml-6 mt-2 border-l border-base-content/10 pl-4"]}
    >
      <li :for={node <- @nodes} data-sort-id={node.id} class="list-none">
        <div class="card flex flex-wrap items-center gap-3 p-3">
          <span data-drag-handle class="cursor-grab text-base-content/40" aria-hidden="true">
            <.icon name="hero-bars-2" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{node.label}</p>
            <p class="truncate font-mono text-xs text-base-content/60">
              {node.url || gettext("(no link)")}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              type="button"
              phx-click="indent_item"
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
              phx-click="outdent_item"
              phx-value-id={node.id}
              aria-label={gettext("Outdent")}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="edit_item"
              phx-value-id={node.id}
              class="btn btn-sm btn-default"
            >
              {gettext("Edit")}
            </button>
            <button
              type="button"
              phx-click="delete_item"
              phx-value-id={node.id}
              data-confirm={gettext("Delete this item and anything nested under it?")}
              aria-label={gettext("Delete item")}
              class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        </div>

        {render_item_form(%{node: node, editing: @editing, current_org: @current_org})}

        {render_level(%{
          nodes: node.children,
          parent_id: node.id,
          depth: @depth + 1,
          items: @items,
          editing: @editing,
          max_depth: @max_depth,
          current_org: @current_org
        })}
      </li>
    </ul>
    """
  end

  # `assigns` here is a plain map built by `render_level/1`, not a socket's
  # assigns — `Phoenix.Component.assign/3` would raise on it.
  defp render_item_form(%{editing: {id, form}, node: %{id: id}} = assigns) do
    assigns = Map.put(assigns, :form, form)

    ~H"""
    <.form
      for={@form}
      id={"edit-item-#{@node.id}"}
      phx-submit="save_item"
      class="mt-2 grid gap-3 rounded border border-primary/40 bg-primary/5 p-3 sm:grid-cols-5"
    >
      <input type="hidden" name="item_id" value={@node.id} />
      <.input field={@form[:label]} label={gettext("Label")} />
      <.input
        field={@form[:link_type]}
        type="select"
        label={gettext("Links to")}
        options={link_type_options()}
      />
      <.input
        field={@form[:target_type]}
        type="select"
        label={gettext("Content type")}
        options={type_options(@current_org)}
      />
      <.input field={@form[:target_slug]} label={gettext("Slug")} />
      <.input field={@form[:url]} label={gettext("or URL")} />
      <.input
        field={@form[:open_in_new_tab]}
        type="select"
        label={gettext("Open in")}
        options={[{gettext("Same tab"), "false"}, {gettext("New tab"), "true"}]}
      />
      <.input
        field={@form[:visible]}
        type="select"
        label={gettext("Visible")}
        options={[{gettext("Shown"), "true"}, {gettext("Hidden"), "false"}]}
      />
      <div class="flex items-end gap-2 sm:col-span-3">
        <.button variant="primary" size="sm">{gettext("Save")}</.button>
        <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-default">
          {gettext("Cancel")}
        </button>
      </div>
    </.form>
    """
  end

  defp render_item_form(assigns), do: ~H""
end
