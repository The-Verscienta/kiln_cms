defmodule KilnCMSWeb.ContentEditor.FlexibleComponents do
  @moduledoc """
  The content editor's input for a `:flexible` custom field (#2282): an ordered
  list of item cards, each of one of the field's item types, with an "Add item"
  menu listing the types.

  A card shows a type badge, a one-line summary, a drag handle, move up/down,
  collapse, duplicate and remove, then the type's content sub-fields and, under
  a Settings disclosure, its `item_setting` ones. A sub-field that is itself a
  flexible field renders the same list inside the card, down to the depth cap.

  The wire form (`custom_fields[<field>][<index>][_id|_type|<sub>]`,
  `[<index>][_settings][<sub>]`) and the events that edit it are
  `KilnCMSWeb.ContentEditor.FlexibleItems`'. Every event addresses an item by
  its `_id` path, and every card's DOM id is keyed by that path, so what a
  collapsed card holds follows the item, not its position.

  Collapse and the Settings disclosure are `Phoenix.LiveView.JS` toggles of a
  data attribute, kept across patches with `JS.ignore_attributes/1`; the CSS
  that hides a body (`.flex-card`, `.flex-settings` in `app.css`) leaves its
  inputs in the DOM, so a collapsed card still posts everything it holds, and
  forces it open while it holds an error. Settings inputs are always rendered
  for the same reason: a save replaces an item's settings rather than merging
  them, so a missing one would be wiped.
  """

  use KilnCMSWeb, :html

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMSWeb.ContentEditor.Conditional
  alias KilnCMSWeb.ContentEditor.FlexibleItems
  alias KilnCMSWeb.ContentEditor.InspectorComponents

  attr :definition, :map, required: true
  # The input name of the field, `form[custom_fields][<name>]`.
  attr :name, :string, required: true
  # The items as the form holds them (`FlexibleItems.posted/2`).
  attr :value, :any, required: true
  attr :errors, :list, default: []

  def flexible_field(assigns) do
    items = FlexibleItems.items(assigns.value)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:problems, FlexibleItems.errors(assigns.errors, assigns.definition, items))

    ~H"""
    <.flexible_list
      definition={@definition}
      address={@definition.name}
      name={@name}
      items={@items}
      problems={@problems}
      depth={1}
    />
    """
  end

  attr :definition, :map, required: true
  attr :address, :string, required: true
  attr :name, :string, required: true
  attr :items, :list, required: true
  attr :problems, :map, required: true
  attr :depth, :integer, required: true

  defp flexible_list(assigns) do
    definition = assigns.definition
    list_id = "custom-field-" <> FlexibleItems.dom_key(assigns.address)

    field_errors =
      if assigns.depth == 1,
        do: assigns.problems.field,
        else: Map.get(assigns.problems.lists, assigns.address, [])

    assigns =
      assigns
      |> assign(:list_id, list_id)
      |> assign(:types, FieldDefinition.item_types(definition))
      |> assign(:full?, FlexibleItems.full?(assigns.items, definition))
      |> assign(:at_minimum?, FlexibleItems.at_minimum?(assigns.items, definition))
      |> assign(:last, length(assigns.items) - 1)
      |> assign(:field_errors, field_errors)

    ~H"""
    <div
      id={@list_id}
      role="group"
      aria-labelledby={"#{@list_id}-label"}
      aria-describedby={@field_errors != [] && "#{@list_id}-errors"}
      class={@depth > 1 && "rounded-lg border-l-2 border-base-content/15 pl-3"}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{@list_id}-label"} class="text-sm font-medium">{@definition.label}</span>
        <span :if={@items != []} class="text-xs text-base-content/70">
          {items_count(@items, @definition)}
        </span>
      </div>
      <input type="hidden" name={"#{@name}[_]"} value="" />
      <ol
        :if={@items != []}
        id={"#{@list_id}-items"}
        phx-hook="Sortable"
        data-sort-event="flex_reorder"
        data-sort-field={@address}
        data-sort-handle={~s([data-flex-handle="#{@list_id}"])}
        class="space-y-2"
      >
        <.flexible_card
          :for={{item, index} <- Enum.with_index(@items)}
          definition={@definition}
          item={item}
          index={index}
          items={@items}
          list_id={@list_id}
          address={@address}
          name={@name}
          problems={@problems}
          depth={@depth}
          last={@last}
          at_minimum?={@at_minimum?}
        />
      </ol>
      <p :if={@items == []} class="text-sm text-base-content/70">{gettext("No items yet.")}</p>
      <%= if @types == [] do %>
        <p class="mt-2 text-sm text-base-content/70">
          {gettext("This field has no item types yet. An admin adds them under Custom fields.")}
        </p>
      <% else %>
        <.add_menu
          list_id={@list_id}
          address={@address}
          types={@types}
          items={@items}
          full?={@full?}
        />
      <% end %>
      <p :if={@full?} class="mt-1 text-xs text-base-content/70">
        {gettext("That's the most this field holds.")}
      </p>
      <p :if={@definition.help_text && @depth == 1} class="mt-1 text-xs text-base-content/70">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list id={"#{@list_id}-errors"} errors={@field_errors} />
    </div>
    """
  end

  attr :list_id, :string, required: true
  attr :address, :string, required: true
  attr :types, :list, required: true
  attr :items, :list, required: true
  attr :full?, :boolean, required: true

  # The disclosure of the content list's New menu (#2145): the click opens it
  # client-side, `data-autoclose` hands outside clicks and Escape to app.js,
  # and a type's own click closes it through the same JS commands, which
  # LiveView re-applies after every patch.
  defp add_menu(assigns) do
    assigns =
      assigns
      |> assign(:toggle_id, assigns.list_id <> "-add")
      |> assign(:menu_id, assigns.list_id <> "-add-menu")

    ~H"""
    <div class="relative mt-2 inline-block" data-autoclose>
      <button
        type="button"
        id={@toggle_id}
        class="btn btn-sm btn-default group"
        disabled={@full?}
        aria-expanded="false"
        aria-controls={@menu_id}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={
          JS.toggle_attribute({"aria-expanded", "true", "false"})
          |> JS.toggle_attribute({"hidden", "hidden"}, to: "##{@menu_id}")
        }
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("Add item")}
        <.icon
          name="hero-chevron-down"
          class="size-3.5 transition-transform group-aria-expanded:rotate-180"
        />
      </button>
      <div
        id={@menu_id}
        hidden
        phx-mounted={JS.ignore_attributes(["hidden"])}
        class="absolute left-0 z-30 mt-2 flex max-h-96 w-64 flex-col gap-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-100 p-1.5 shadow-lg"
      >
        <button
          :for={type <- @types}
          type="button"
          id={"#{@list_id}-add-#{type.name}"}
          disabled={FlexibleItems.type_full?(@items, type)}
          phx-click={
            JS.push("flex_add", value: %{at: @address, type: type.name})
            |> JS.set_attribute({"hidden", "hidden"}, to: "##{@menu_id}")
            |> JS.set_attribute({"aria-expanded", "false"}, to: "##{@toggle_id}")
          }
          class="rounded-md px-2.5 py-1.5 text-left text-sm hover:bg-base-200 disabled:pointer-events-none disabled:opacity-40"
        >
          <span class="block font-medium">{type.label}</span>
          <span :if={type.help_text} class="block text-xs text-base-content/70">
            {type.help_text}
          </span>
          <span
            :if={FlexibleItems.type_full?(@items, type)}
            class="block text-xs text-base-content/70"
          >
            {gettext("Full")}
          </span>
        </button>
      </div>
    </div>
    """
  end

  attr :definition, :map, required: true
  attr :item, :map, required: true
  attr :index, :integer, required: true
  attr :items, :list, required: true
  attr :list_id, :string, required: true
  attr :address, :string, required: true
  attr :name, :string, required: true
  attr :problems, :map, required: true
  attr :depth, :integer, required: true
  attr :last, :integer, required: true
  attr :at_minimum?, :boolean, required: true

  defp flexible_card(assigns) do
    %{definition: definition, item: item, index: index} = assigns
    key = FlexibleItems.key(item, index)
    address = assigns.address <> "/" <> key
    type = FlexibleItems.type(definition, item)
    subs = if type, do: FieldDefinition.group_fields(type), else: []
    {setting_subs, content_subs} = Enum.split_with(subs, &FlexibleItems.setting?/1)
    settings = if is_map(item["_settings"]), do: item["_settings"], else: %{}
    entry = Map.get(assigns.problems.items, address, %{item: [], cells: %{}})

    assigns =
      assigns
      |> assign(:key, key)
      |> assign(:address, address)
      |> assign(:card_id, "cf-flex-" <> FlexibleItems.dom_key(address))
      |> assign(:item_name, "#{assigns.name}[#{index}]")
      |> assign(:type, type)
      |> assign(:subs, subs)
      |> assign(:content_subs, content_subs)
      |> assign(:setting_subs, setting_subs)
      |> assign(:row, Map.merge(Map.drop(item, ["_settings"]), settings))
      |> assign(:entry, entry)
      |> assign(:errors?, FlexibleItems.errors?(assigns.problems, address))
      |> assign(:summary, FlexibleItems.summary(item, type))
      |> assign(:addressable?, is_binary(item["_id"]) and item["_id"] != "")
      |> assign(
        :duplicable?,
        type != nil and not FlexibleItems.full?(assigns.items, definition) and
          not FlexibleItems.type_full?(assigns.items, type)
      )

    ~H"""
    <li
      id={@card_id}
      data-sort-id={@key}
      data-flex-card
      data-collapsed="false"
      data-errors={to_string(@errors?)}
      phx-mounted={JS.ignore_attributes(["data-collapsed"])}
      class={[
        "flex-card rounded-lg border bg-base-200/30 p-3 transition-colors",
        if(@errors?,
          do: "border-error/50",
          else: "border-base-content/10 hover:border-base-content/20"
        )
      ]}
    >
      <input :if={@addressable?} type="hidden" name={"#{@item_name}[_id]"} value={@item["_id"]} />
      <input type="hidden" name={"#{@item_name}[_type]"} value={@item["_type"]} />
      <%= if @type do %>
        <div class="flex items-center justify-between gap-2">
          <div class="flex min-w-0 flex-1 items-center gap-1">
            <button
              type="button"
              data-drag-handle
              data-flex-handle={@list_id}
              aria-label={gettext("Drag to reorder item %{position}", position: @index + 1)}
              title={gettext("Drag to reorder")}
              class="-ml-1 cursor-grab rounded p-1 text-base-content/70 hover:bg-base-200 hover:text-base-content active:cursor-grabbing"
            >
              <.icon name="hero-bars-2" class="size-4" />
            </button>
            <button
              type="button"
              id={"#{@card_id}-toggle"}
              aria-expanded="true"
              aria-controls={"#{@card_id}-body"}
              phx-mounted={JS.ignore_attributes(["aria-expanded"])}
              phx-click={
                JS.toggle_attribute({"data-collapsed", "true", "false"}, to: "##{@card_id}")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
              class="group flex min-w-0 flex-1 items-center gap-2 rounded px-1 py-0.5 text-left hover:bg-base-200"
            >
              <.icon
                name="hero-chevron-down"
                class="size-4 shrink-0 text-base-content/70 transition-transform group-aria-[expanded=false]:-rotate-90"
              />
              <span class="shrink-0 rounded bg-base-200 px-1.5 py-0.5 text-xs font-medium">
                {@type.label}
              </span>
              <span
                :if={@summary}
                class="min-w-0 truncate text-sm text-base-content/70"
              >
                {@summary}
              </span>
              <span :if={@errors?} class="shrink-0 text-error">
                <.icon name="hero-exclamation-circle" class="size-4" />
                <span class="sr-only">{gettext("Needs attention")}</span>
              </span>
            </button>
          </div>
          <div class="flex shrink-0 items-center gap-0.5">
            <button
              type="button"
              id={"#{@card_id}-up"}
              phx-click="flex_move"
              phx-value-at={@address}
              phx-value-dir="up"
              disabled={@index == 0 or not @addressable?}
              aria-label={gettext("Move item %{position} up", position: @index + 1)}
              class="btn btn-sm btn-ghost px-1.5"
            >
              <.icon name="hero-chevron-up" class="size-4" />
            </button>
            <button
              type="button"
              id={"#{@card_id}-down"}
              phx-click="flex_move"
              phx-value-at={@address}
              phx-value-dir="down"
              disabled={@index == @last or not @addressable?}
              aria-label={gettext("Move item %{position} down", position: @index + 1)}
              class="btn btn-sm btn-ghost px-1.5"
            >
              <.icon name="hero-chevron-down" class="size-4" />
            </button>
            <button
              type="button"
              id={"#{@card_id}-duplicate"}
              phx-click="flex_duplicate"
              phx-value-at={@address}
              disabled={not @duplicable? or not @addressable?}
              aria-label={gettext("Duplicate item %{position}", position: @index + 1)}
              title={gettext("Duplicate")}
              class="btn btn-sm btn-ghost px-1.5"
            >
              <.icon name="hero-document-duplicate" class="size-4" />
            </button>
            <.remove_button
              card_id={@card_id}
              address={@address}
              index={@index}
              at_minimum?={@at_minimum?}
              definition={@definition}
            />
          </div>
        </div>
        <div id={"#{@card_id}-body"} class="flex-card-body mt-3">
          <div class="grid gap-3 sm:grid-cols-2">
            <.item_cell
              :for={sub <- @content_subs}
              sub={sub}
              subs={@subs}
              row={@row}
              item={@item}
              item_name={@item_name}
              address={@address}
              problems={@problems}
              depth={@depth}
            />
          </div>
          <p
            :for={message <- @entry.item}
            class="mt-2 flex items-center gap-1 text-xs text-error"
          >
            <.icon name="hero-exclamation-circle" class="size-4" /> {message}
          </p>
          <.settings_section
            :if={@setting_subs != []}
            card_id={@card_id}
            setting_subs={@setting_subs}
            subs={@subs}
            row={@row}
            item={@item}
            item_name={@item_name}
            address={@address}
            entry={@entry}
            problems={@problems}
            depth={@depth}
          />
        </div>
      <% else %>
        <div class="flex items-center justify-between gap-2">
          <div class="flex min-w-0 items-center gap-2">
            <.icon name="hero-lock-closed" class="size-4 shrink-0 text-base-content/70" />
            <span class="shrink-0 rounded bg-base-200 px-1.5 py-0.5 text-xs font-medium">
              {@item["_type"] || gettext("Unknown")}
            </span>
            <span class="text-sm text-base-content/70">
              {gettext(
                "This item's type no longer exists on this field, so it can't be edited. Saving removes it."
              )}
            </span>
          </div>
          <.remove_button
            card_id={@card_id}
            address={@address}
            index={@index}
            at_minimum?={false}
            definition={@definition}
          />
        </div>
      <% end %>
    </li>
    """
  end

  attr :card_id, :string, required: true
  attr :address, :string, required: true
  attr :index, :integer, required: true
  attr :at_minimum?, :boolean, required: true
  attr :definition, :map, required: true

  defp remove_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@card_id}-remove"}
      phx-click="flex_remove"
      phx-value-at={@address}
      disabled={@at_minimum?}
      aria-label={gettext("Remove item %{position}", position: @index + 1)}
      title={
        @at_minimum? &&
          ngettext(
            "This field needs at least one item.",
            "This field needs at least %{count} items.",
            @definition.min_items
          )
      }
      class="rounded px-1.5 py-1 text-base-content/70 transition-colors hover:bg-base-200 hover:text-error disabled:pointer-events-none disabled:opacity-40"
    >
      <.icon name="hero-trash" class="size-4" />
    </button>
    """
  end

  attr :card_id, :string, required: true
  attr :setting_subs, :list, required: true
  attr :subs, :list, required: true
  attr :row, :map, required: true
  attr :item, :map, required: true
  attr :item_name, :string, required: true
  attr :address, :string, required: true
  attr :entry, :map, required: true
  attr :problems, :map, required: true
  attr :depth, :integer, required: true

  # Always rendered, hidden by CSS only (`.flex-settings`): the save replaces
  # an item's settings, so an input that was not in the DOM would wipe its
  # setting. Open by default when one of them holds an error.
  defp settings_section(assigns) do
    names = Enum.map(assigns.setting_subs, & &1.name)

    assigns =
      assigns
      |> assign(:settings_id, assigns.card_id <> "-settings")
      |> assign(
        :errors?,
        Enum.any?(names, &Map.has_key?(assigns.entry.cells, &1)) or
          Enum.any?(assigns.setting_subs, fn sub ->
            sub.field_type == :flexible and
              FlexibleItems.errors?(assigns.problems, assigns.address <> "/" <> sub.name)
          end)
      )

    ~H"""
    <div
      id={@settings_id}
      class="flex-settings mt-3 border-t border-base-content/10 pt-2"
      data-open="false"
      data-errors={to_string(@errors?)}
      phx-mounted={JS.ignore_attributes(["data-open"])}
    >
      <button
        type="button"
        id={"#{@settings_id}-toggle"}
        aria-expanded="false"
        aria-controls={"#{@settings_id}-body"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={
          JS.toggle_attribute({"data-open", "true", "false"}, to: "##{@settings_id}")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
        class="group flex items-center gap-1 rounded px-1 py-0.5 text-xs font-medium text-base-content/70 hover:bg-base-200"
      >
        <.icon
          name="hero-chevron-down"
          class="size-3.5 transition-transform group-aria-[expanded=false]:-rotate-90"
        />
        {gettext("Settings")}
        <span :if={@errors?} class="text-error">
          <.icon name="hero-exclamation-circle" class="size-3.5" />
          <span class="sr-only">{gettext("Needs attention")}</span>
        </span>
      </button>
      <%!-- The hiding element carries no display utility of its own: a
            utility (`grid`) would outrank the `.flex-settings` rule. --%>
      <div id={"#{@settings_id}-body"} class="flex-settings-body mt-2">
        <div class="grid gap-3 sm:grid-cols-2">
          <.item_cell
            :for={sub <- @setting_subs}
            sub={sub}
            subs={@subs}
            row={@row}
            item={@item}
            item_name={@item_name}
            address={@address}
            problems={@problems}
            depth={@depth}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :sub, :map, required: true
  # The item type's sub-fields and the item's values (content and settings
  # together), for `visible_when` (#2277).
  attr :subs, :list, required: true
  attr :row, :map, required: true
  attr :item, :map, required: true
  attr :item_name, :string, required: true
  attr :address, :string, required: true
  attr :problems, :map, required: true
  attr :depth, :integer, required: true

  # One sub-field of one item, through the same inputs a top-level field gets
  # (`InspectorComponents.group_cell_input/1`), under an id of its own keyed by
  # the item's `_id` chain. A nested flexible sub-field is a whole list, one
  # level down. The browser's `required` stays off, as in a group row: a blank
  # card is dropped on save, so it must never block one.
  defp item_cell(assigns) do
    sub = assigns.sub
    key = FlexibleItems.dom_key(assigns.address) <> "-" <> sub.name

    name =
      if FlexibleItems.setting?(sub),
        do: "#{assigns.item_name}[_settings][#{sub.name}]",
        else: "#{assigns.item_name}[#{sub.name}]"

    entry = Map.get(assigns.problems.items, assigns.address, %{cells: %{}})

    assigns =
      assigns
      |> assign(:key, key)
      |> assign(:cell_name, name)
      |> assign(:state, Conditional.effective(assigns.subs, &Map.get(assigns.row, &1))[sub.name])
      |> assign(:errors, Map.get(entry.cells, sub.name, []))
      |> assign(
        :wide?,
        sub.field_type in [:flexible, :text]
      )

    ~H"""
    <div class={["min-w-0 has-[>.hidden]:hidden", @wide? && "sm:col-span-2"]}>
      <Conditional.conditional
        id={"cf-cond-#{@key}"}
        definition={@sub}
        prefix={String.replace_suffix(@cell_name, "[#{@sub.name}]", "")}
        state={@state}
        required={false}
      >
        <%= if @sub.field_type == :flexible do %>
          <.flexible_list
            definition={@sub}
            address={@address <> "/" <> @sub.name}
            name={@cell_name}
            items={FlexibleItems.sub_items(@item, @sub)}
            problems={@problems}
            depth={@depth + 1}
          />
        <% else %>
          <InspectorComponents.group_cell_input
            sub={@sub}
            key={@key}
            name={@cell_name}
            value={cell_value(@item, @sub)}
            errors={@errors}
          />
        <% end %>
      </Conditional.conditional>
    </div>
    """
  end

  defp cell_value(item, sub) do
    if FlexibleItems.setting?(sub),
      do: item |> Map.get("_settings") |> settings_value(sub.name),
      else: Map.get(item, sub.name)
  end

  defp settings_value(%{} = settings, name), do: Map.get(settings, name)
  defp settings_value(_none, _name), do: nil

  attr :id, :string, required: true
  attr :errors, :list, required: true

  defp custom_field_errors_list(assigns) do
    ~H"""
    <div :if={@errors != []} id={@id} class="mt-1 space-y-0.5">
      <p :for={message <- @errors} class="flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-4" /> {message}
      </p>
    </div>
    """
  end

  defp items_count(items, %{max_items: max}) when is_integer(max),
    do: gettext("%{count} of %{max} items", count: length(items), max: max)

  defp items_count(items, _definition),
    do: ngettext("%{count} item", "%{count} items", length(items))
end
