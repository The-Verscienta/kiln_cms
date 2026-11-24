defmodule KilnCMSWeb.ContentEditor.ReferencePicker do
  @moduledoc """
  The content editor's input for a `:reference` custom field (R9 in
  `docs/relationships-plan.md`): a search-as-you-type combobox over the
  target type, and the picked records as rows — one row for a single
  reference, an ordered list for a `multiple` one.

  ## Who holds what

  The **value** stays in the content form, as it does for every other field:
  the rows carry hidden inputs named into `custom_fields` (an id for a single
  reference; `name[]` with a leading blank for a list, the gallery's shape),
  so a save posts what `ApplyCustomFields` already expects. The component
  never writes the value itself. A pick, a removal or a reorder is sent to the
  editor LiveView as `{#{inspect(__MODULE__)}, {op, field, arg}}`, and the
  editor rewrites the form params and re-validates — the same path every list
  edit takes, so the optimistic lock, the dirty state and the working copy
  behave as they do for a typed-in value.

  What the component holds is the **search**: the query, one page of
  results, whether the list is open. Searching is a read of the target type
  as the editor's actor, in the editor's tenant, paginated and uncapped — the
  read policies decide what can be found, so a search never surfaces a record
  the editor could not open.

  ## Create and connect

  Next to the search, the picker offers "Add new *Type*" for each target type
  the editor may create (`ContentTypes.can_create?/4`, the type's generated
  `can_create_*?` helper — the policy the create itself runs). It opens a
  small form inline: the title and the type's required fields that have no
  default, nothing else. The record is created as the editor, through the
  type's own create action (`ContentTypes.create!/3`), so it starts as an
  ordinary draft, and is then connected exactly as a pick is — the same
  `:add`/`:put` message, so the editor's lock and working copy are untouched.
  Abandoning the source's change leaves the new draft in the content list;
  nothing deletes it.

  The small form renders the plain field types only (text, numbers, a yes/no,
  dates, a URL, a choice). A type with a required field it cannot render — a
  media or reference field, a composite or plugin type — and no default is not
  offered here: the create would be refused, and the menu never offers what
  the server would refuse. Such a record is made in its own editor.

  The form's inputs are named under `_kiln_ref_new`, outside the editor
  form's own params (as the search's `_kiln_ref_q` is), and carry their own
  `phx-change`, so typing into them never touches the document.

  ## Details on each connection (R3)

  A field that declares link fields (`FieldDefinition.link_fields/1`) renders
  one input per link field on every row, under the record's title: the
  quantity of each ingredient, the role of each author. They are plain form
  inputs of the editor form, named `<form>[_kiln_ref_link][<field>][<row
  key>][<link field>]` beside the row's hidden id, so typing into one is an
  ordinary change event. `ReferenceValues.normalize/2` folds them into the
  field's value as each item's `"link"` map before the params reach the form,
  and `ApplyCustomFields` coerces them like any other field. A row's key is
  its id (or `"type:id"` token), so moving or removing a row carries its
  values with it.

  ## A dropdown instead of the search (#2284)

  A single reference whose widget is `"dropdown"`
  (`KilnCMS.CMS.FieldWidgets.effective/1`) lists its candidates in a
  `<select>` in place of the search box. Everything else stays as above: the
  hidden input still holds the value, the picked row (and its link inputs)
  still shows under it, and choosing an option is a pick — the same `:put`
  (or, for "— None —", `:remove`) message to the editor. The `<select>` is
  named under `_kiln_ref_pick`, outside the editor form's own params, so it
  never posts a value of its own.

  The candidates are read once per picker, as the editor's actor in the
  editor's tenant, title-sorted and grouped by type on a field that allows
  several. At most 100 across all the target types: past that the
  picker keeps the search and says why. The current pick is always an
  option, even one the list doesn't hold (a record just made with "Add new",
  or one the editor can't read, which shows as unavailable). A target full
  under `max_sources` is listed, disabled.

  A list of references, the reverse field's add control and the related
  content picker (none of which offer a widget) always search.

  ## Thumbnails (#3223)

  Each result and row shows its record's featured image, small and
  decorative (`alt=""`): the generated `"thumb"` variant or a video's
  poster, never the original (`thumb/1`). The image loads with the read that
  lists the records (`thumb_load/0`), as the editor, so a page of results
  costs one more query per type read, not one per record. A row without one
  keeps an empty slot only when another row of its list has one.

  ## Seams for later workstreams

    * `row/1` is public and takes `readonly`, so the reverse list (R4) can
      render the same row without the controls, and an `:actions` slot for
      controls of its own (R4b).
    * `notify: {module, id}` sends picks to that component instead of the
      editor, and `rows: false` renders the search alone: the reverse field's
      add control (R4b), whose connections are other records' values, not
      this form's.
    * The `:row_extra` slot renders inside each row, after the title (and the
      link inputs), with the row's item.
    * `exclude` names record ids the search never offers, beside the ones
      already picked: the record being edited, for the related-content list
      (#2025), which runs this picker over its own type with a definition
      the editor builds rather than a stored field.
    * Results and rows name their type, and `target_types/2` is the one
      place that turns a definition into the types to search.

  ## Several target types (R2)

  A field that allows several types (`FieldDefinition.target_types`) keys
  every result and row by a `"type:id"` token instead of a bare id
  (`KilnCMSWeb.ContentEditor.ReferenceValues`), so the hidden inputs and the
  edit messages say which type each record is, and the editor turns the
  tokens into the `%{"id", "type"}` a write needs. The search reads every
  allowed type and merges them into one list in the same order.
  """

  use KilnCMSWeb, :live_component

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldWidgets
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.ReferenceSelection
  alias KilnCMSWeb.ContentEditor.PlainField
  alias KilnCMSWeb.ContentEditor.ReferenceInline
  alias KilnCMSWeb.ContentEditor.ReferenceValues
  alias KilnCMSWeb.MediaComponents

  @page_size 20

  # The most candidates the dropdown widget lists, across every target type;
  # past it the picker searches instead.
  @select_limit 100

  # The field types the "Add new" form can render. A required field of any
  # other type (and no default) keeps its content type out of the menu.
  @creatable_field_types [
    :string,
    :text,
    :integer,
    :float,
    :boolean,
    :date,
    :datetime,
    :url,
    :select
  ]

  # ── lifecycle ─────────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:more?, false)
     |> assign(:open?, false)
     |> assign(:known, %{})
     |> assign(:ids, nil)
     |> assign(:creatable, nil)
     |> assign(:summary, nil)
     |> assign(:plans, nil)
     |> assign(:candidates, nil)
     |> assign(:creating, nil)
     |> assign(:inline_ok, %{})
     |> assign(:inline_open, %{})
     |> assign(:inline_dirty, %{})
     |> assign(:announcement, "")}
  end

  @impl true
  # A record card reporting (#2283): its edits are unsaved or not, or it saved
  # a draft and the row should show the new title.
  def update(%{inline_event: event}, socket), do: {:ok, inline_event(socket, event)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:locked, fn -> false end)
      |> assign_new(:row_extra, fn -> [] end)
      |> assign_new(:source, fn -> nil end)
      |> assign_new(:notify, fn -> nil end)
      |> assign_new(:rows, fn -> true end)
      |> assign_new(:placeholder, fn -> nil end)
      |> assign_new(:exclude, fn -> [] end)
      |> assign_new(:key, fn -> assigns.definition.name end)
      |> assign_new(:address, fn -> nil end)
      |> assign_new(:link_name, fn -> link_name(assigns.name) end)
      |> assign(:link_fields, FieldDefinition.link_fields(assigns.definition))
      |> assign(:links, ReferenceValues.links(assigns.value, assigns.definition))

    ids =
      assigns.value
      |> ReferenceValues.keys(ReferenceValues.polymorphic?(assigns.definition))
      |> Enum.uniq()

    # Without rows (the reverse field's add control, R4b) the ids only keep
    # records already connected out of the results; nothing shows them.
    socket =
      cond do
        ids == socket.assigns.ids -> socket
        not socket.assigns.rows -> assign(socket, :ids, ids)
        true -> socket |> assign(:ids, ids) |> resolve(ids)
      end

    socket =
      if socket.assigns.creatable == nil,
        do: assign(socket, :creatable, creatable(socket.assigns)),
        else: socket

    # The selection's read plan per target type, resolved once: resolving it
    # reads tags, categories and field definitions, which a keystroke must not.
    socket =
      if socket.assigns.plans == nil,
        do: assign(socket, :plans, plans(socket.assigns)),
        else: socket

    socket =
      if socket.assigns.summary == nil,
        do: assign(socket, :summary, summary(socket.assigns)),
        else: socket

    # The dropdown widget's options: read once, like `creatable` (#2284).
    socket =
      if socket.assigns.candidates == nil,
        do: assign(socket, :candidates, candidates(socket)),
        else: socket

    {:ok,
     socket
     |> assign(:items, items(socket.assigns))
     |> assign_capacity()
     |> assign_inline()}
  end

  # The rows that get a record card (`edit_inline`, #2283): the connected
  # records the actor may write, decided once per row (one read per target
  # type, for the rows not yet decided). An open card of a row that left the
  # field is dropped. The server re-decides when a card opens.
  defp assign_inline(%{assigns: %{rows: true, definition: %{edit_inline: true}}} = socket) do
    %{items: items, inline_ok: decided, inline_open: open} = socket.assigns
    keys = Enum.map(items, & &1.id)

    # The record being edited never gets a card on its own field: its write
    # would move the very row the parent's Save is built on.
    decided =
      Map.merge(
        decided,
        Map.new(Enum.filter(items, &parent?(&1, socket.assigns)), &{&1.id, false})
      )

    fresh = Enum.reject(items, &(Map.has_key?(decided, &1.id) or is_nil(&1.state)))

    decided =
      if fresh == [] do
        decided
      else
        cts =
          Map.new(
            target_types(socket.assigns.definition, socket.assigns.tenant),
            &{to_string(&1.type), &1}
          )

        Map.merge(
          decided,
          ReferenceInline.writable(cts, fresh, socket.assigns.actor, socket.assigns.tenant)
        )
      end

    socket
    |> assign(:inline_ok, Map.take(decided, keys))
    |> assign(:inline_open, Map.take(open, keys))
    |> update(:inline_dirty, &Map.take(&1, keys))
  end

  defp assign_inline(socket), do: socket

  defp inline_event(socket, {:dirty, key, dirty?}) do
    update(socket, :inline_dirty, fn dirty ->
      if dirty?, do: Map.put(dirty, key, true), else: Map.delete(dirty, key)
    end)
  end

  # A draft's row title is its live title; a published record's is not
  # touched by a working-copy save.
  defp inline_event(socket, {:saved, key, :draft, title}) do
    known = socket.assigns.known

    case known do
      %{^key => item} ->
        socket
        |> assign(:known, Map.put(known, key, %{item | title: title}))
        |> then(&assign(&1, :items, items(&1.assigns)))

      _unknown ->
        socket
    end
  end

  defp inline_event(socket, {:saved, _key, _state, _title}), do: socket

  defp parent?(item, %{source: %{id: id, type: type}}) when is_binary(id),
    do: Map.get(item, :record_id) == id and to_string(item.type) == type

  defp parent?(_item, _assigns), do: false

  # Whether the search shows: never on a locked field; on a list until it
  # holds `max_items`; on a single reference while it is empty. `pick` checks
  # the same flag, so a hand-sent pick can't overfill a list either.
  defp assign_capacity(socket) do
    %{definition: definition, items: items, locked: locked} = socket.assigns
    count = length(items)

    full? =
      definition.multiple == true and is_integer(definition.max_items) and
        count >= definition.max_items

    searchable? =
      not locked and if(definition.multiple == true, do: not full?, else: count == 0)

    socket
    |> assign(:full?, full?)
    |> assign(:searchable?, searchable?)
    # A form left open when the field fills up (or locks) has nothing left to
    # connect to.
    |> update(:creating, &if(searchable?, do: &1))
  end

  # ── events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("ref_open", _params, socket) do
    if socket.assigns.open?,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:open?, true) |> search(0)}
  end

  def handle_event("ref_close", _params, socket),
    do: {:noreply, assign(socket, :open?, false)}

  def handle_event("ref_search", %{"_kiln_ref_q" => queries}, socket) when is_map(queries) do
    query = queries |> Map.get(socket.assigns.key, "") |> to_string()

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:open?, true)
     |> search(0)}
  end

  def handle_event("ref_search", _params, socket), do: {:noreply, socket}

  def handle_event("ref_more", _params, socket),
    do: {:noreply, search(socket, length(socket.assigns.results))}

  # Only an id this search offered: the editor re-validates whatever it is
  # handed, but a pick is a choice from the list, not an open door for ids.
  def handle_event("ref_pick", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.results, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      _offered when not socket.assigns.searchable? ->
        {:noreply, socket}

      # A target the field's `max_sources` says is full (R1b) is listed, not
      # pickable: the save would be refused.
      %{full?: true} ->
        {:noreply, socket}

      result ->
        notify(socket, if(multiple?(socket), do: :add, else: :put), id)

        socket = update(socket, :known, &Map.put(&1, id, result))

        # A list stays open for the next pick, minus the one just taken;
        # a single reference is done.
        if multiple?(socket),
          do: {:noreply, update(socket, :results, &Enum.reject(&1, fn r -> r.id == id end))},
          else: {:noreply, socket |> assign(:open?, false) |> assign(:query, "")}
    end
  end

  # The dropdown widget's choice (#2284): an id among the candidates it was
  # offered, or blank for "— None —". Sent on as a pick or a removal, as the
  # search's are; a full target, an id it never offered, or a locked field
  # changes nothing.
  def handle_event("ref_select", %{"_kiln_ref_pick" => picks}, socket) when is_map(picks) do
    id = picks |> Map.get(socket.assigns.key, "") |> to_string()
    current = List.first(socket.assigns.ids || [])

    if socket.assigns.locked or not is_list(socket.assigns.candidates),
      do: {:noreply, socket},
      else: {:noreply, select_pick(socket, id, current)}
  end

  def handle_event("ref_select", _params, socket), do: {:noreply, socket}

  def handle_event("ref_remove", %{"id" => id}, socket) when is_binary(id) do
    notify(socket, :remove, id)
    {:noreply, socket}
  end

  def handle_event("ref_move", %{"id" => id, "dir" => dir}, socket)
      when is_binary(id) and dir in ["up", "down"] do
    notify(socket, :move, {id, dir})
    {:noreply, socket}
  end

  def handle_event("ref_reorder", %{"order" => order}, socket) when is_list(order) do
    notify(socket, :reorder, Enum.filter(order, &is_binary/1))
    {:noreply, socket}
  end

  # ── create and connect ──

  # Offered only while the field can take another record — the same flag the
  # search shows on — so a hand-sent event can't open it on a full list.
  def handle_event("ref_new", %{"type" => type}, socket) when is_binary(type) do
    case creatable_type(socket, type) do
      nil ->
        {:noreply, socket}

      _entry when not socket.assigns.searchable? ->
        {:noreply, socket}

      _entry ->
        {:noreply,
         socket
         |> assign(:creating, %{type: type, params: %{}, errors: []})
         |> assign(:open?, false)}
    end
  end

  def handle_event("ref_new_change", %{"_kiln_ref_new" => forms}, socket) when is_map(forms) do
    case {socket.assigns.creating, Map.get(forms, socket.assigns.key)} do
      {%{} = creating, %{} = params} ->
        {:noreply, assign(socket, :creating, %{creating | params: params})}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("ref_new_change", _params, socket), do: {:noreply, socket}

  def handle_event("ref_new_cancel", _params, socket),
    do: {:noreply, assign(socket, :creating, nil)}

  def handle_event("ref_new_create", _params, socket) do
    with %{type: type, params: params} <- socket.assigns.creating,
         true <- socket.assigns.searchable?,
         %{} = entry <- creatable_type(socket, type) do
      {:noreply, create_and_connect(socket, entry, params)}
    else
      _nothing -> {:noreply, socket}
    end
  end

  # Create-on-type (#2285): the row at the end of the results. It carries no
  # value: the title is the search text the server holds and the type is the
  # field's own `selection.create`, both re-checked here, so a forged or stale
  # event for a row that is not offered does nothing.
  def handle_event("ref_create_typed", _params, socket) do
    case typed_create(socket.assigns, grants?: true) do
      nil ->
        {:noreply, socket}

      %{entry: entry, title: title} ->
        # The query is cleared first either way: a double click's second event
        # finds nothing typed and does nothing, so one click makes one draft.
        socket = socket |> assign(:query, "") |> assign(:results, []) |> assign(:more?, false)

        if entry.fields == [] do
          # The form holds the title while it is created, so a refusal
          # stays visible under it instead of vanishing with the click.
          socket =
            assign(socket, :creating, %{type: entry.key, params: %{"title" => title}, errors: []})

          {:noreply, create_and_connect(socket, entry, %{"title" => title})}
        else
          {:noreply,
           socket
           |> assign(:creating, %{type: entry.key, params: %{"title" => title}, errors: []})
           |> assign(:open?, false)}
        end
    end
  end

  # A record card (#2283) opens or closes. The row key must be one of the
  # field's current values, and the server re-reads the record and re-checks
  # that the actor may write it: a forged key opens nothing.
  def handle_event("inline_toggle", %{"id" => key}, socket) when is_binary(key) do
    %{definition: definition, ids: ids, inline_ok: decided, inline_open: open} = socket.assigns

    cond do
      definition.edit_inline != true or not socket.assigns.rows ->
        {:noreply, socket}

      Map.has_key?(socket.assigns.inline_dirty, key) ->
        {:noreply,
         assign(
           socket,
           :announcement,
           gettext("Save or discard the changes to this record before closing it.")
         )}

      Map.has_key?(open, key) ->
        {:noreply, assign(socket, :inline_open, Map.delete(open, key))}

      key not in ids or Map.get(decided, key) != true ->
        {:noreply, socket}

      map_size(open) >= ReferenceInline.max_open() ->
        {:noreply,
         assign(socket, :announcement, gettext("Close a record before opening another."))}

      true ->
        {:noreply, open_card(socket, key)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp open_card(socket, key) do
    %{items: items, definition: definition, tenant: tenant} = socket.assigns
    item = Enum.find(items, &(&1.id == key))

    ct =
      item &&
        Enum.find(target_types(definition, tenant), &(to_string(&1.type) == to_string(item.type)))

    if ct,
      do: update(socket, :inline_open, &Map.put(&1, key, %{ct: ct, record_id: item.record_id})),
      else: socket
  end

  # The create-on-type row, or nil: what the field's `selection.create` offers
  # for what is typed. Needs a non-blank query, a search that shows, the
  # type in `creatable` (rights, the field's lock, the form's support), a
  # selection a new draft would pass, and no record titled the same among
  # what the filtered search found or is already picked.
  defp typed_create(assigns, opts \\ []) do
    selection = Map.get(assigns.definition, :selection)
    title = assigns.query |> String.trim()
    type = ReferenceSelection.create_type(selection)

    with true <- type != nil and title != "" and String.length(title) <= 255,
         true <- assigns.searchable? and not assigns.locked and not is_list(assigns.candidates),
         nil <- ReferenceSelection.create_problem(selection, type),
         %{prefill: {:ok, _values}} = entry <- creatable_type(assigns, type),
         true <-
           not Keyword.get(opts, :grants?, false) or
             prefill_writable?(entry, assigns.actor, assigns.tenant),
         # More matches than one page shows: the exact title may be on a later page.
         false <- assigns.more?,
         false <- title_listed?(title, assigns) do
      %{entry: entry, title: title}
    else
      _no -> nil
    end
  end

  defp title_listed?(title, assigns) do
    wanted = fold(title)

    Enum.any?(assigns.results ++ assigns.items, fn item ->
      fold(Map.get(item, :title) || "") == wanted
    end)
  end

  defp fold(text), do: text |> String.trim() |> String.downcase()

  # The values a created record is given for the selection's plain equality
  # conditions (`selection.create_values`), all of which the actor must be
  # allowed to write on the TARGET type, and each a field that takes a plain
  # given value: not computed, not unique, no dynamic default.
  defp prefill(ct, selection, actor, tenant) do
    values = ReferenceSelection.create_values(selection, ct.type)

    defs =
      if values == %{},
        do: [],
        else:
          ct |> field_definitions(actor, tenant) |> Enum.filter(&Map.has_key?(values, &1.name))

    cond do
      Enum.any?(defs, &(not plain_field?(&1))) -> :blocked
      length(defs) != map_size(values) -> :blocked
      not prefill_writable?(%{ct: ct, prefill: {:ok, values}}, actor, tenant) -> :blocked
      true -> {:ok, values}
    end
  end

  defp plain_field?(%{field_type: :computed}), do: false
  defp plain_field?(%{default_source: source}) when not is_nil(source), do: false

  defp plain_field?(%{validation: %{} = validation}),
    do: Map.get(validation, "unique", Map.get(validation, :unique)) not in [true, "true"]

  defp plain_field?(_definition), do: true

  defp prefill_writable?(%{ct: ct, prefill: {:ok, values}}, actor, tenant) do
    grant = Scoping.field_grant(actor, tenant, to_string(ct.type))
    Enum.all?(Map.keys(values), &FieldAccess.writable?(grant, [&1]))
  end

  defp prefill_writable?(_entry, _actor, _tenant), do: false

  defp select_pick(socket, "", nil), do: socket

  defp select_pick(socket, "", current) do
    notify(socket, :remove, current)
    socket
  end

  defp select_pick(socket, current, current), do: socket

  defp select_pick(socket, id, _current) do
    case Enum.find(socket.assigns.candidates, &(&1.id == id)) do
      %{full?: true} ->
        socket

      %{} = candidate ->
        notify(socket, :put, id)
        update(socket, :known, &Map.put(&1, id, candidate))

      nil ->
        socket
    end
  end

  defp creatable_type(%{assigns: assigns}, type), do: creatable_type(assigns, type)
  defp creatable_type(assigns, type), do: Enum.find(assigns.creatable || [], &(&1.key == type))

  # Created as the editor through the type's own create action, then connected
  # the way a pick is. A refusal or an invalid value stays in the form.
  defp create_and_connect(socket, entry, params) do
    %{actor: actor, tenant: tenant} = socket.assigns
    title = params |> Map.get("title", "") |> to_string() |> String.trim()

    if title == "" do
      set_create_errors(socket, [gettext("Give it a title.")])
    else
      attrs = %{title: title, custom_fields: new_custom_fields(entry, params)}

      try do
        record = ContentTypes.create!(entry.ct, attrs, actor: actor, tenant: tenant)
        # Keyed as a pick is: the id, or its `"type:id"` token on a field
        # that allows several types.
        item = to_item(record, entry.ct, socket.assigns.definition)

        notify(socket, if(multiple?(socket), do: :add, else: :put), item.id)

        socket
        |> update(:known, &Map.put(&1, item.id, item))
        |> assign(:creating, nil)
        |> assign(
          :announcement,
          gettext("Created “%{title}” as a draft and connected it.", title: title)
        )
      rescue
        Ash.Error.Forbidden ->
          set_create_errors(socket, [gettext("You can't create this here.")])

        error in Ash.Error.Invalid ->
          set_create_errors(socket, Enum.map(error.errors, &Exception.message/1))
      end
    end
  end

  defp set_create_errors(socket, errors),
    do: update(socket, :creating, &%{&1 | errors: errors})

  # Only the fields the form shows; everything else falls to its default.
  defp new_custom_fields(%{fields: fields} = entry, params) do
    supplied = Map.get(params, "custom_fields", %{})
    supplied = if is_map(supplied), do: supplied, else: %{}

    shown = Map.new(fields, &{&1.name, Map.get(supplied, &1.name, "")})

    # The selection's plain equality values win: they are what makes the new
    # record one the field accepts (#2285), and never come from the client.
    case entry do
      %{prefill: {:ok, values}} when is_map(values) -> Map.merge(shown, values)
      _plain -> shown
    end
  end

  # To the editor LiveView, which owns the form — or, with `notify:
  # {module, id}`, to the component that owns the connection (the reverse
  # field, R4b), as an update carrying `picked: {op, arg}`.
  defp notify(%{assigns: %{notify: {module, id}}}, op, arg),
    do: send_update(module, id: id, picked: {op, arg})

  # A picker inside a flexible item (#2282, `address` is the item's `_id`
  # address) names the item and the sub-field instead of a top-level field.
  defp notify(%{assigns: %{address: address}} = socket, op, arg) when is_binary(address),
    do: send(self(), {__MODULE__, {:item, address, socket.assigns.definition.name, op, arg}})

  defp notify(socket, op, arg),
    do: send(self(), {__MODULE__, {op, socket.assigns.definition.name, arg}})

  # ── reads ─────────────────────────────────────────────────────────────────

  @doc """
  The content types a reference definition may point at, resolved in `org`:
  its one `target_type`, or every type in `target_types` (R2). A name that no
  longer resolves is left out.
  """
  def target_types(definition, org) do
    for name <- FieldDefinition.reference_targets(definition),
        ct = ContentTypes.get(name, org),
        not is_nil(ct),
        do: ct
  end

  # The target types the editor may create a record of here, each with the
  # required fields the "Add new" form asks for. `nil` (not `[]`) until
  # computed, so it is read once per picker. A locked field offers nothing
  # anyway, so a locked picker skips the reads.
  defp creatable(%{locked: true}), do: []

  defp creatable(%{definition: definition, tenant: tenant, actor: actor}) do
    selection = Map.get(definition, :selection)
    create_type = ReferenceSelection.create_type(selection)

    definition
    |> target_types(tenant)
    |> Enum.flat_map(&creatable_for(&1, create_type, selection, actor, tenant))
  end

  defp creatable_for(ct, create_type, selection, actor, tenant) do
    with true <- ContentTypes.can_create?(ct, actor, %{}, tenant: tenant),
         {:ok, fields} <- form_fields(ct, actor, tenant) do
      prefill =
        if create_type == to_string(ct.type),
          do: prefill(ct, selection, actor, tenant),
          else: {:ok, %{}}

      [creatable_entry(ct, fields, prefill)]
    else
      _not_here -> []
    end
  end

  # A prefilled field is the selection's, so the form does not ask for it.
  defp creatable_entry(ct, fields, prefill) do
    values = if match?({:ok, %{}}, prefill), do: elem(prefill, 1), else: %{}
    fields = Enum.reject(fields, &Map.has_key?(values, &1.name))
    %{key: to_string(ct.type), ct: ct, label: ct.label, fields: fields, prefill: prefill}
  end

  # The dropdown widget's candidates (#2284): `:off` unless this picker is a
  # single reference whose widget is the dropdown, `:too_many` past
  # `@select_limit` records across the target types, else every readable
  # record of them, title-sorted, each marked full under `max_sources`. Read
  # as the editor's actor in the editor's tenant, so the list holds what the
  # search could find and nothing else. Each type reads one past the limit,
  # so no read is ever unbounded.
  defp candidates(%{assigns: assigns} = socket) do
    if dropdown?(assigns) do
      assigns.definition
      |> target_types(assigns.tenant)
      |> Enum.flat_map(&read_candidates(socket, &1, @select_limit + 1))
      |> listed_candidates(socket)
    else
      :off
    end
  end

  defp listed_candidates(rows, _socket) when length(rows) > @select_limit, do: :too_many

  defp listed_candidates(rows, socket) do
    rows
    |> Enum.sort_by(fn {record, _ct} -> {record.title || "", record.id} end)
    |> Enum.map(fn {record, ct} -> to_item(record, ct, socket.assigns.definition) end)
    |> with_capacity(socket)
  end

  defp dropdown?(assigns) do
    assigns.rows and is_nil(assigns.notify) and assigns.definition.multiple != true and
      FieldWidgets.effective(assigns.definition) == "dropdown"
  end

  # `{record, ct}` for up to `limit` records of `ct`, by title.
  defp read_candidates(socket, ct, limit) do
    %{definition: definition, tenant: tenant, actor: actor, exclude: exclude} = socket.assigns

    ct
    |> ContentTypes.list!(
      selected(
        [
          actor: actor,
          tenant: tenant,
          query:
            search_filters("", excluded_ids(exclude, ct, definition)) ++
              [
                select: [:id, :title, :state, :slug, :updated_at, :featured_image_id],
                load: thumb_load(),
                sort: [title: :asc, id: :asc],
                limit: limit
              ]
        ],
        socket.assigns.plans,
        ct
      )
    )
    |> Enum.map(&{&1, ct})
  end

  # The required fields with no default — what a create would refuse without —
  # or `:unsupported` when one of them is a type the small form can't render.
  defp form_fields(ct, actor, tenant) do
    needed =
      ct
      |> field_definitions(actor, tenant)
      |> Enum.filter(&(&1.required and &1.default in [nil, ""]))

    if Enum.all?(needed, &(&1.field_type in @creatable_field_types)),
      do: {:ok, needed},
      else: :unsupported
  end

  defp field_definitions(%{source: :dynamic, definition: definition}, actor, tenant),
    do: CMS.field_definitions_for_definition!(definition.id, actor: actor, tenant: tenant)

  defp field_definitions(ct, actor, tenant),
    do: CMS.field_definitions_for!(ct.type, actor: actor, tenant: tenant)

  # One page of the target type, as the actor. A blank query lists the most
  # recently edited first — usually what an editor is about to link — and a
  # typed one lists matches by title. Records already picked are left out of
  # a list's results, in the query, so pages stay full.
  defp search(socket, offset) do
    %{definition: definition, tenant: tenant, query: query} = socket.assigns
    picked = if multiple?(socket), do: socket.assigns.ids, else: []
    exclude = picked ++ socket.assigns.exclude

    case target_types(definition, tenant) do
      [] ->
        socket |> assign(:results, []) |> assign(:more?, false)

      cts ->
        rows = search_rows(socket, cts, query, exclude, offset)
        {page, rest} = Enum.split(rows, @page_size)

        page =
          page
          |> Enum.map(fn {record, ct} -> to_item(record, ct, definition) end)
          |> with_capacity(socket)

        results = if offset == 0, do: page, else: socket.assigns.results ++ page

        socket
        |> assign(:results, results)
        |> assign(:more?, rest != [])
    end
  end

  # One type reads its page directly. Several (R2) each read everything up to
  # the end of the page, and the merge, sorted the way one read would be,
  # drops what earlier pages showed — so paging stays exact across types.
  defp search_rows(socket, [ct], query, exclude, offset),
    do: socket |> read_type(ct, query, exclude, @page_size + 1, offset) |> Enum.map(&{&1, ct})

  defp search_rows(socket, cts, query, exclude, offset) do
    cts
    |> Enum.flat_map(fn ct ->
      socket
      |> read_type(ct, query, exclude, offset + @page_size + 1, 0)
      |> Enum.map(&{&1, ct})
    end)
    |> sort_merged(query, socket.assigns.definition)
    |> Enum.drop(offset)
    |> Enum.take(@page_size + 1)
  end

  defp read_type(socket, ct, query, exclude, limit, offset) do
    %{definition: definition, tenant: tenant, actor: actor} = socket.assigns

    ContentTypes.list!(
      ct,
      selected(
        [
          actor: actor,
          tenant: tenant,
          query:
            search_filters(query, excluded_ids(exclude, ct, definition)) ++
              [
                select: [:id, :title, :state, :slug, :updated_at, :featured_image_id],
                load: thumb_load(),
                sort: search_sort(query, definition),
                limit: limit,
                offset: offset
              ]
        ],
        socket.assigns.plans,
        ct
      )
    )
  end

  # The field's `selection` (#2285) as one more AND on this read — the same
  # evaluator, and the same read action, as the save-time check, so the
  # picker cannot offer what a save refuses. It only narrows: the read still
  # runs as the actor, whose policy decides what can be found at all. The
  # reverse field's synthetic definition carries none.
  defp plans(%{definition: definition, tenant: tenant, actor: actor}) do
    for ct <- target_types(definition, tenant), into: %{} do
      {:ok, plan} =
        ReferenceSelection.query_for(Map.get(definition, :selection), ct.type, actor, tenant)

      {to_string(ct.type), plan}
    end
  end

  defp selected(opts, plans, ct),
    do: ReferenceSelection.read_opts(opts, Map.get(plans, to_string(ct.type), :unfiltered))

  # What the active selection reads as, once per picker: a list of short
  # phrases for the footer and the empty state, or `:none` when the field has
  # no selection (or nothing live is left of it).
  defp summary(%{definition: definition, tenant: tenant}) do
    targets = FieldDefinition.reference_targets(definition)

    with selection when not is_nil(selection) <- Map.get(definition, :selection),
         %{} = described <- ReferenceSelection.describe(selection, targets, tenant),
         [_ | _] = phrases <- phrases(described, definition, tenant) do
      phrases
    else
      _none -> :none
    end
  end

  defp phrases(described, definition, tenant) do
    labels = definition |> target_types(tenant) |> Map.new(&{to_string(&1.type), &1.label})

    states =
      case described.states do
        [] ->
          []

        states ->
          [gettext("State: %{states}", states: Enum.map_join(states, ", ", &state_name/1))]
      end

    owner = if described.owner == :self, do: [gettext("Created by you")], else: []

    typed =
      for {type, entry} <- Enum.sort(described.by_type),
          condition <- type_phrases(entry) do
        label = Map.get(labels, type, type)

        if map_size(described.by_type) > 1 or ReferenceValues.polymorphic?(definition),
          do: "#{label}: #{condition}",
          else: condition
      end

    states ++ owner ++ typed
  end

  defp type_phrases(entry) do
    tags =
      if entry.tags == [],
        do: [],
        else: [
          gettext("Tagged %{tags}", tags: Enum.join(entry.tags, " " <> gettext("or") <> " "))
        ]

    category =
      if entry.category, do: [gettext("Category %{name}", name: entry.category)], else: []

    fields =
      for {label, values} <- entry.fields,
          do:
            gettext("%{field} is %{values}",
              field: label,
              values: Enum.join(values, " " <> gettext("or") <> " ")
            )

    tags ++ category ++ fields
  end

  defp state_name("draft"), do: gettext("Draft")
  defp state_name("in_review"), do: gettext("In review")
  defp state_name("published"), do: gettext("Published")
  defp state_name("archived"), do: gettext("Archived")

  defp sort_merged(rows, query, definition) do
    if recent?(query, definition),
      do: Enum.sort(rows, &newer_first?/2),
      else: Enum.sort_by(rows, fn {record, _ct} -> {record.title || "", record.id} end)
  end

  # A blank search lists newest first unless the field's selection sorts by
  # title; a typed one is always by title.
  defp recent?(query, definition),
    do:
      String.trim(query) == "" and
        ReferenceSelection.sort(Map.get(definition, :selection)) == "recent"

  defp newer_first?({a, _}, {b, _}) do
    case DateTime.compare(a.updated_at, b.updated_at) do
      :gt -> true
      :lt -> false
      :eq -> a.id <= b.id
    end
  end

  # The picked keys' record ids that belong to `ct`.
  defp excluded_ids(keys, ct, definition) do
    for key <- keys,
        {type, id} = split_key(key, definition),
        type == to_string(ct.type),
        do: id
  end

  # A row key as `{type name, record id}`: a `"type:id"` token on a field that
  # allows several types, else a bare id of the field's one type.
  defp split_key(key, definition) do
    with true <- ReferenceValues.polymorphic?(definition),
         [type, id] <- String.split(key, ":", parts: 2) do
      {type, id}
    else
      _bare -> {definition |> FieldDefinition.reference_targets() |> List.first(), key}
    end
  end

  defp search_filters(query, exclude) do
    text =
      case String.trim(query) do
        "" ->
          []

        term ->
          pattern = "%" <> String.replace(term, ~r/([\\%_])/, "\\\\\\1") <> "%"
          [filter: expr(ilike(title, ^pattern))]
      end

    picked = if exclude == [], do: [], else: [filter: expr(id not in ^exclude)]
    text ++ picked
  end

  defp search_sort(query, definition) do
    if recent?(query, definition),
      do: [updated_at: :desc, id: :asc],
      else: [title: :asc, id: :asc]
  end

  # Title, type and state for the picked ids this component hasn't seen yet,
  # read as the actor. An id that doesn't come back — deleted, in the trash,
  # or not readable by this editor — is shown from its stored snapshot and
  # marked unavailable, never dropped: dropping it would quietly unlink it on
  # the next save.
  defp resolve(socket, ids) do
    %{definition: definition, tenant: tenant, actor: actor, known: known} = socket.assigns
    cts = Map.new(target_types(definition, tenant), &{to_string(&1.type), &1})

    found =
      ids
      |> Enum.reject(&Map.has_key?(known, &1))
      |> Enum.map(&split_key(&1, definition))
      |> Enum.filter(fn {type, id} -> Map.has_key?(cts, type) and uuid?(id) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {type, missing} ->
        ct = cts[type]

        ct
        |> ContentTypes.list!(
          actor: actor,
          tenant: tenant,
          query: [
            filter: [id: [in: missing]],
            select: [:id, :title, :state, :slug, :featured_image_id],
            load: thumb_load()
          ]
        )
        |> Enum.map(&to_item(&1, ct, definition))
      end)
      |> Map.new(&{&1.id, &1})

    assign(socket, :known, Map.merge(known, found))
  end

  defp uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  # `id` is the row's key: the record id, or its `"type:id"` token on a field
  # that allows several types.
  defp to_item(record, ct, definition) do
    type = to_string(ct.type)

    %{
      id:
        if(ReferenceValues.polymorphic?(definition),
          do: ReferenceValues.token(type, record.id),
          else: record.id
        ),
      record_id: record.id,
      title: record.title,
      state: record.state,
      type: ct.type,
      type_label: ct.label,
      href: ~p"/editor/content/#{type}/#{record.id}",
      thumb: thumb(record)
    }
  end

  @doc """
  The `load:` that gives a read of content records what `thumb/1` needs: each
  record's featured image, with only the fields the thumbnail rule reads. A
  relationship load, so it runs as the read's own actor and tenant — one
  query per read, never one per record — and a featured image the actor
  cannot read, or one in the trash, loads as `nil`.
  """
  def thumb_load do
    [
      featured_image: Ash.Query.select(MediaItem, [:id, :url, :variants, :content_type, :width])
    ]
  end

  @doc """
  A record's small preview for a row (#3223): its featured image's generated
  `"thumb"` variant, or a video's poster — never the full-size original —
  or `nil` when it has none, or when the image was not loaded (`thumb_load/0`).
  """
  def thumb(%{featured_image: %MediaItem{} = image}),
    do: MediaComponents.thumb_src(image, fallback: false)

  def thumb(_record), do: nil

  # Each result's connection count through this field when it has a
  # `max_sources` (R1b), so a full target is listed but disabled — "Full —
  # 3 of 3 connected" — instead of missing or refused on save. The record
  # being edited is left out of the count: connecting it to a target it
  # already holds is not an add. Counted from the edges, in one read, as the
  # editor (who sees every edge of the site).
  defp with_capacity(items, socket) do
    %{definition: definition, source: source, actor: actor, tenant: tenant} = socket.assigns

    case definition do
      %{max_sources: max} when is_integer(max) and items != [] ->
        counts = connection_counts(items, definition, source, actor, tenant)

        Enum.map(items, fn item ->
          count = Map.get(counts, item.record_id, 0)
          Map.merge(item, %{connected: count, full?: count >= max})
        end)

      _uncapped ->
        items
    end
  end

  defp connection_counts(items, definition, source, actor, tenant) do
    ids = Enum.map(items, & &1.record_id)
    {source_id, source_type} = if source, do: {source.id, source.type}, else: {nil, nil}

    filter =
      [kind: :reference, field: definition.name, target_id: [in: ids]] ++
        if(source_type, do: [source_type: source_type], else: [])

    [actor: actor, tenant: tenant, query: [filter: filter, select: [:id, :source_id, :target_id]]]
    |> CMS.list_content_links!()
    |> Enum.reject(&(&1.source_id == source_id))
    |> Enum.frequencies_by(& &1.target_id)
  end

  defp items(%{ids: ids, known: known, value: value, definition: definition}) do
    polymorphic? = ReferenceValues.polymorphic?(definition)

    snapshots =
      value
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"id" => _} = snapshot ->
          Enum.map(ReferenceValues.keys(snapshot, polymorphic?), &{&1, snapshot})

        _other ->
          []
      end)
      |> Map.new()

    Enum.map(ids, fn id ->
      Map.get_lazy(known, id, fn ->
        snapshot = Map.get(snapshots, id, %{})

        %{
          id: id,
          title: snapshot["title"],
          state: nil,
          type: snapshot["type"] || elem(split_key(id, definition), 0),
          type_label: nil,
          href: nil,
          thumb: nil
        }
      end)
    end)
  end

  defp multiple?(socket), do: socket.assigns.definition.multiple == true

  # `form[custom_fields][field]` → `form[_kiln_ref_link][field]`, the param
  # `ReferenceValues.normalize/2` folds back in.
  defp link_name(name),
    do: String.replace(name, "[custom_fields][", "[_kiln_ref_link][", global: false)

  # ── rendering ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:multiple?, assigns.definition.multiple == true)
      |> assign(:root, "custom-field-#{assigns.key}")
      |> assign(:last, length(assigns.items) - 1)
      |> assign(:dropdown?, is_list(assigns.candidates))
      |> assign(:typed, assigns.open? and typed_create(assigns))
      |> assign(:items_thumbs?, Enum.any?(assigns.items, &Map.get(&1, :thumb)))
      |> assign(:results_thumbs?, Enum.any?(assigns.results, &Map.get(&1, :thumb)))

    ~H"""
    <div
      id={@root}
      phx-hook="ReferencePicker"
      phx-target={@myself}
      role="group"
      aria-labelledby={"#{@root}-label"}
      aria-describedby={@errors != [] && "#{@root}-errors"}
      data-reference-picker={@key}
    >
      <div class={["mb-1 flex items-baseline justify-between gap-2", !@rows && "sr-only"]}>
        <span id={"#{@root}-label"} class="text-sm font-medium">{@definition.label}</span>
        <span
          :if={@rows and @multiple? and @items != []}
          class="text-xs tabular-nums text-base-content/60"
        >
          {count_label(length(@items), @definition.max_items)}
        </span>
      </div>

      <input :if={@rows and @multiple?} type="hidden" name={"#{@name}[]"} value="" />
      <input
        :if={@rows and not @multiple?}
        type="hidden"
        name={@name}
        value={List.first(@ids) || ""}
      />

      <ol
        :if={@rows and @items != []}
        id={"#{@root}-items"}
        data-ref-items
        aria-label={gettext("Connected records")}
        class="divide-y divide-base-content/10 overflow-hidden rounded-md border border-base-content/10"
      >
        <.row
          :for={{item, index} <- Enum.with_index(@items)}
          id={"cf-ref-#{@key}-#{String.replace(item.id, ":", "-")}"}
          item={item}
          index={index}
          last={@last}
          input_name={@multiple? && "#{@name}[]"}
          sortable={@multiple? and not @locked and @last > 0}
          readonly={@locked}
          target={@myself}
          thumb_slot={@items_thumbs?}
        >
          <:extra :if={@link_fields != []}>
            <.link_inputs
              id={"cf-ref-#{@key}-#{String.replace(item.id, ":", "-")}-link"}
              fields={@link_fields}
              name={"#{@link_name}[#{item.id}]"}
              values={Map.get(@links, item.id, %{})}
              title={item.title}
              readonly={@locked}
            />
          </:extra>
          <:extra :for={extra <- @row_extra}>{render_slot(extra, item)}</:extra>
          <:extra :if={@definition.edit_inline == true and Map.get(@inline_ok, item.id) == true}>
            <% row_id = "cf-ref-#{@definition.name}-#{String.replace(item.id, ":", "-")}-inline" %>
            <ReferenceInline.toggle
              id={row_id}
              item={item}
              open?={Map.has_key?(@inline_open, item.id)}
              target={@myself}
            />
            <.live_component
              :if={Map.has_key?(@inline_open, item.id)}
              module={ReferenceInline}
              id={"#{@id}-inline-#{item.id}"}
              dom_id={row_id}
              picker_id={@id}
              field={@definition.name}
              key={item.id}
              ct={@inline_open[item.id].ct}
              record_id={@inline_open[item.id].record_id}
              actor={@actor}
              tenant={@tenant}
              connected?={item.id in @ids}
              locked?={@locked}
            />
          </:extra>
        </.row>
      </ol>

      <p :if={@rows and @items == [] and not @searchable?} class="text-sm text-base-content/60">
        {gettext("Nothing connected yet.")}
      </p>

      <.candidate_select
        :if={@dropdown? and not @locked}
        root={@root}
        key={@key}
        definition={@definition}
        candidates={@candidates}
        current={List.first(@items)}
        errors={@errors}
        target={@myself}
      />

      <p
        :if={@candidates == :too_many and @searchable?}
        id={"#{@root}-too-many"}
        class="mb-1 text-xs text-base-content/70"
      >
        {gettext("Too many to list — search instead.")}
      </p>

      <div
        :if={@searchable? and not @dropdown?}
        class={["relative", (@rows and @items != []) && "mt-2"]}
        phx-click-away={@open? && JS.push("ref_close", target: @myself)}
      >
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="text"
            id={"#{@root}-search"}
            name={"_kiln_ref_q[#{@key}]"}
            value={@query}
            role="combobox"
            autocomplete="off"
            spellcheck="false"
            aria-autocomplete="list"
            aria-expanded={to_string(@open?)}
            aria-controls={"#{@root}-listbox"}
            aria-labelledby={"#{@root}-label"}
            aria-describedby={"#{@root}-status"}
            aria-invalid={@errors != [] && "true"}
            placeholder={@placeholder || search_placeholder(@multiple?, @items)}
            phx-change="ref_search"
            phx-focus="ref_open"
            phx-debounce="200"
            phx-target={@myself}
            data-ref-search
            class="field-input pl-8"
          />
        </div>
        <ul
          :if={@open?}
          id={"#{@root}-listbox"}
          role="listbox"
          aria-label={gettext("Matching records")}
          class="absolute inset-x-0 top-full z-20 mt-1 max-h-72 overflow-y-auto rounded-md border border-base-content/10 bg-base-100 py-1 shadow-lg"
        >
          <li
            :for={result <- @results}
            id={"#{@root}-opt-#{String.replace(result.id, ":", "-")}"}
            role="option"
            aria-selected="false"
            aria-disabled={to_string(Map.get(result, :full?, false))}
            data-ref-option
            phx-click={!Map.get(result, :full?) && "ref_pick"}
            phx-value-id={result.id}
            phx-target={@myself}
            class={[
              "flex items-center gap-2 px-3 py-1.5 text-sm transition-colors",
              if(Map.get(result, :full?),
                do: "cursor-not-allowed text-base-content/50",
                else: "cursor-pointer hover:bg-base-200 aria-selected:bg-primary/10"
              )
            ]}
          >
            <.thumb_image src={result.thumb} slot={@results_thumbs?} />
            <span class="min-w-0 flex-1 truncate">{result.title || gettext("Untitled")}</span>
            <span
              :if={Map.get(result, :full?)}
              id={"#{@root}-opt-#{String.replace(result.id, ":", "-")}-full"}
              class="shrink-0 rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
            >
              {gettext("Full — %{count} of %{max} connected",
                count: result.connected,
                max: @definition.max_sources
              )}
            </span>
            <span class="shrink-0 text-xs text-base-content/60">{result.type_label}</span>
            <.state_badge state={result.state} class="shrink-0" />
          </li>
          <li
            :if={@more?}
            id={"#{@root}-more"}
            role="option"
            aria-selected="false"
            data-ref-option
            phx-click="ref_more"
            phx-target={@myself}
            class="cursor-pointer px-3 py-1.5 text-sm text-primary-ink transition-colors hover:bg-base-200 aria-selected:bg-primary/10"
          >
            {gettext("Show more results")}
          </li>
          <li
            :if={@typed}
            id={"#{@root}-create-typed"}
            role="option"
            aria-selected="false"
            data-ref-option
            phx-click="ref_create_typed"
            phx-target={@myself}
            class="flex cursor-pointer items-center gap-2 border-t border-base-content/10 px-3 py-1.5 text-sm text-primary-ink transition-colors hover:bg-base-200 aria-selected:bg-primary/10"
          >
            <.icon name="hero-plus" class="size-4 shrink-0" />
            <span class="min-w-0 flex-1 truncate">
              {gettext("Create “%{title}” as a new %{type}",
                title: @typed.title,
                type: @typed.entry.label
              )}
            </span>
            <span class="shrink-0 text-xs text-base-content/70">{gettext("Draft")}</span>
          </li>
          <li :if={@results == []} role="presentation" class="px-3 py-2 text-sm text-base-content/60">
            {no_results_label(@query)}
            <span :if={@summary != :none and String.trim(@query) == ""} id={"#{@root}-filter-empty"}>
              {gettext("This field only accepts records that match: %{conditions}.",
                conditions: Enum.join(@summary, "; ")
              )}
            </span>
          </li>
          <li
            :if={@summary != :none and not (@results == [] and String.trim(@query) == "")}
            id={"#{@root}-filter"}
            role="presentation"
            class="border-t border-base-content/10 px-3 py-1.5 text-xs text-base-content/70"
          >
            {gettext("Only offering: %{conditions}", conditions: Enum.join(@summary, "; "))}
          </li>
        </ul>
        <p id={"#{@root}-status"} class="sr-only" aria-live="polite">
          {status_label(@open?, @results, @more?)}
        </p>
      </div>

      <div
        :if={@searchable? and @creatable != [] and is_nil(@creating)}
        id={"#{@root}-new"}
        class="mt-1.5 flex flex-wrap gap-x-3 gap-y-1"
      >
        <button
          :for={entry <- @creatable}
          type="button"
          id={"#{@root}-new-#{entry.key}"}
          phx-click="ref_new"
          phx-value-type={entry.key}
          phx-target={@myself}
          class="inline-flex cursor-pointer items-center gap-1 rounded text-xs font-medium text-primary-ink transition-colors hover:underline"
        >
          <.icon name="hero-plus" class="size-3.5" />
          {gettext("Add new %{type}", type: entry.label)}
        </button>
      </div>

      <.new_record_form
        :if={@creating}
        root={@root}
        field={@key}
        entry={creatable_type(assigns, @creating.type)}
        creating={@creating}
        target={@myself}
      />
      <p class="sr-only" aria-live="polite">{@announcement}</p>

      <p :if={@full?} class="mt-1 text-xs text-base-content/60">
        {gettext("The limit is reached. Remove one to connect another.")}
      </p>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <div :if={@errors != []} id={"#{@root}-errors"}>
        <p :for={message <- @errors} class="mt-1 flex items-center gap-1 text-xs text-error">
          <.icon name="hero-exclamation-circle" class="size-4" /> {message}
        </p>
      </div>
    </div>
    """
  end

  attr :root, :string, required: true
  attr :key, :string, required: true
  attr :definition, :map, required: true
  attr :candidates, :list, required: true
  attr :current, :map, default: nil
  attr :errors, :list, required: true
  attr :target, :any, required: true

  # The dropdown widget (#2284): the candidates as options, grouped by type
  # on a field that allows several, under the field's own label. Its name is
  # outside the editor form's params; a change is a pick (`ref_select`). The
  # current pick leads when the list doesn't hold it, so the select always
  # shows what the hidden input holds.
  defp candidate_select(assigns) do
    current = assigns.current
    listed? = current && Enum.any?(assigns.candidates, &(&1.id == current.id))

    assigns =
      assigns
      |> assign(:current_id, current && current.id)
      |> assign(:stray, if(current && !listed?, do: current))
      |> assign(:groups, candidate_groups(assigns.candidates, assigns.definition))

    ~H"""
    <div class="mb-1.5">
      <select
        id={"#{@root}-select"}
        name={"_kiln_ref_pick[#{@key}]"}
        aria-labelledby={"#{@root}-label"}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && "#{@root}-errors"}
        phx-change="ref_select"
        phx-target={@target}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :if={@stray} value={@stray.id} selected>
          {if @stray.state, do: @stray.title || gettext("Untitled"), else: gettext("Unavailable")}
        </option>
        <%= for {label, candidates} <- @groups do %>
          <%= if label do %>
            <optgroup label={label}>
              <.candidate_option
                :for={candidate <- candidates}
                candidate={candidate}
                current={@current_id}
                max={@definition.max_sources}
              />
            </optgroup>
          <% else %>
            <.candidate_option
              :for={candidate <- candidates}
              candidate={candidate}
              current={@current_id}
              max={@definition.max_sources}
            />
          <% end %>
        <% end %>
      </select>
    </div>
    """
  end

  attr :candidate, :map, required: true
  attr :current, :string, default: nil
  attr :max, :integer, default: nil

  # A target full under `max_sources` is listed, disabled, and says so —
  # unless it is the current pick, which a re-save doesn't add to.
  defp candidate_option(assigns) do
    ~H"""
    <option
      value={@candidate.id}
      selected={@candidate.id == @current}
      disabled={Map.get(@candidate, :full?, false) and @candidate.id != @current}
    >
      {@candidate.title || gettext("Untitled")}
      <%= if Map.get(@candidate, :full?) do %>
        · {gettext("Full — %{count} of %{max} connected", count: @candidate.connected, max: @max)}
      <% end %>
    </option>
    """
  end

  # `[{type label | nil, candidates}]`: one unlabelled run on a field of one
  # type; one group per type, in the field's own type order, on several.
  defp candidate_groups(candidates, definition) do
    if ReferenceValues.polymorphic?(definition) do
      order = definition |> FieldDefinition.reference_targets() |> Enum.with_index() |> Map.new()

      candidates
      |> Enum.group_by(&{&1.type, &1.type_label})
      |> Enum.sort_by(fn {{type, _label}, _cs} -> Map.get(order, to_string(type), 0) end)
      |> Enum.map(fn {{_type, label}, cs} -> {label, cs} end)
    else
      [{nil, candidates}]
    end
  end

  attr :root, :string, required: true
  attr :field, :string, required: true
  attr :entry, :map, required: true
  attr :creating, :map, required: true
  attr :target, :any, required: true

  # The "Add new" form. Not a `<form>` — it renders inside the editor's own —
  # so its inputs carry their own `phx-change` and the hook turns Enter into
  # the create button and Escape into Cancel.
  defp new_record_form(assigns) do
    assigns =
      assigns
      |> assign(:prefix, "_kiln_ref_new[#{assigns.field}]")
      |> assign(:form_id, "#{assigns.root}-new-form")

    ~H"""
    <div
      id={@form_id}
      role="group"
      aria-labelledby={"#{@form_id}-heading"}
      data-ref-new
      class="mt-2 space-y-3 rounded-md border border-base-content/10 bg-base-200/40 p-3"
    >
      <div class="flex items-baseline justify-between gap-2">
        <p id={"#{@form_id}-heading"} class="text-sm font-medium">
          {gettext("New %{type}", type: @entry.label)}
        </p>
        <span class="text-xs text-base-content/60">
          {gettext("Saved as a draft and connected here.")}
        </span>
      </div>
      <div>
        <label for={"#{@form_id}-title"} class="mb-1 block text-xs font-medium">
          {gettext("Title")}
        </label>
        <input
          type="text"
          id={"#{@form_id}-title"}
          name={"#{@prefix}[title]"}
          value={@creating.params["title"]}
          autocomplete="off"
          phx-change="ref_new_change"
          phx-target={@target}
          phx-mounted={JS.focus()}
          class="field-input"
        />
      </div>
      <PlainField.field
        :for={definition <- @entry.fields}
        id={"#{@form_id}-cf-#{definition.name}"}
        definition={definition}
        name={"#{@prefix}[custom_fields][#{definition.name}]"}
        value={get_in(@creating.params, ["custom_fields", definition.name])}
        event="ref_new_change"
        target={@target}
      />
      <ul :if={@creating.errors != []} id={"#{@form_id}-errors"} role="alert" class="space-y-0.5">
        <li :for={message <- @creating.errors} class="flex items-center gap-1 text-xs text-error">
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0" /> {message}
        </li>
      </ul>
      <div class="flex items-center justify-end gap-2">
        <button
          type="button"
          phx-click="ref_new_cancel"
          phx-target={@target}
          data-ref-new-cancel
          class="btn btn-ghost btn-sm"
        >
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          id={"#{@form_id}-submit"}
          phx-click="ref_new_create"
          phx-target={@target}
          phx-disable-with={gettext("Creating…")}
          data-ref-new-submit
          class="btn btn-primary btn-sm"
        >
          {gettext("Create and connect")}
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :fields, :list, required: true
  attr :name, :string, required: true
  attr :values, :map, required: true
  attr :title, :string, default: nil
  attr :readonly, :boolean, default: false

  # One connection's link-field inputs (R3): a compact grid under the row's
  # title. Plain inputs of the editor form — no `phx-change` of their own, so
  # an edit validates like any field. Each is labelled with the record, since
  # every row repeats the same labels.
  defp link_inputs(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label={gettext("Details for %{title}", title: @title || gettext("Untitled"))}
      class="mt-1.5 grid gap-x-3 gap-y-1.5 sm:grid-cols-2"
      data-ref-link
    >
      <.link_input
        :for={field <- @fields}
        id={"#{@id}-#{field.name}"}
        field={field}
        name={"#{@name}[#{field.name}]"}
        value={Map.get(@values, field.name)}
        readonly={@readonly}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, :map, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :readonly, :boolean, default: false

  defp link_input(%{field: %{field_type: :boolean}} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 self-end">
      <input type="hidden" name={@name} value="false" disabled={@readonly} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@value in [true, "true"]}
        disabled={@readonly}
        class="size-4 rounded border-base-content/30 accent-primary"
      />
      <label for={@id} class="text-xs text-base-content/70">{@field.label}</label>
    </div>
    """
  end

  defp link_input(%{field: %{field_type: :select}} = assigns) do
    ~H"""
    <div>
      <label for={@id} class="mb-0.5 block text-[11px] font-medium text-base-content/60">
        {@field.label}<span :if={@field.required} class="text-error"> *</span>
      </label>
      <select id={@id} name={@name} disabled={@readonly} class="field-select py-1 text-sm">
        <option value="">{gettext("— None —")}</option>
        <option
          :for={option <- @field.options}
          value={option}
          selected={to_string(@value || @field.default) == option}
        >
          {FieldDefinition.option_label(@field, option)}
        </option>
      </select>
    </div>
    """
  end

  defp link_input(assigns) do
    assigns = assign(assigns, :type, PlainField.input_type(assigns.field.field_type))

    ~H"""
    <div>
      <label for={@id} class="mb-0.5 block text-[11px] font-medium text-base-content/60">
        {@field.label}<span :if={@field.required} class="text-error"> *</span>
      </label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        placeholder={@field.default}
        step={@field.field_type == :float && "any"}
        title={@field.help_text}
        autocomplete="off"
        disabled={@readonly}
        class="field-input py-1 text-sm"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "`id`, `title`, `state`, `type_label`, `href`, `thumb`"
  attr :index, :integer, default: 0
  attr :last, :integer, default: 0
  attr :input_name, :any, default: nil, doc: "the `name[]` a list row submits its id under"
  attr :sortable, :boolean, default: false
  attr :readonly, :boolean, default: false
  attr :target, :any, default: nil

  attr :thumb_slot, :boolean,
    default: false,
    doc: "whether any row of the list has a thumbnail, so a row without one keeps the space"

  slot :extra, doc: "rendered after the title — per-link inputs (R3)"
  slot :actions, doc: "controls of the caller's own, before the row's own (R4b)"

  @doc """
  One connected record: title, type and state, with "open" and — unless
  `readonly` — move and remove controls. Shared with read-only lists of
  connected records.
  """
  def row(assigns) do
    ~H"""
    <li
      id={@id}
      data-sort-id={@item.id}
      class="group flex items-center gap-2 bg-base-100 px-2 py-1.5 transition-colors hover:bg-base-200/60"
    >
      <input :if={@input_name} type="hidden" name={@input_name} value={@item.id} />
      <span
        :if={@sortable}
        data-drag-handle
        title={gettext("Drag to reorder")}
        class="flex shrink-0 cursor-grab items-center text-base-content/30 transition-colors group-hover:text-base-content/60 active:cursor-grabbing"
      >
        <.icon name="hero-bars-2" class="size-4" />
      </span>
      <span
        :if={@input_name}
        class="flex size-5 shrink-0 items-center justify-center rounded-full bg-base-200 text-[10px] font-semibold tabular-nums text-base-content/70"
      >
        {@index + 1}
      </span>
      <.thumb_image src={Map.get(@item, :thumb)} slot={@thumb_slot} />
      <div class="min-w-0 flex-1">
        <p class="truncate text-sm">{@item.title || gettext("Untitled")}</p>
        <p class="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs text-base-content/60">
          <span :if={@item.type_label}>{@item.type_label}</span>
          <.state_badge :if={@item.state} state={@item.state} />
          <span
            :if={!@item.state}
            title={gettext("Deleted, in the trash, or not visible to you")}
            class="inline-flex items-center gap-1 text-warning-ink"
          >
            <.icon name="hero-exclamation-triangle" class="size-3.5" />
            {gettext("Unavailable")}
          </span>
        </p>
        {render_slot(@extra)}
      </div>
      <div class="flex shrink-0 items-center gap-0.5">
        {render_slot(@actions)}
        <.link
          :if={@item.href}
          href={@item.href}
          target="_blank"
          rel="noopener"
          aria-label={
            gettext("Open %{title} in a new tab", title: @item.title || gettext("Untitled"))
          }
          title={gettext("Open in a new tab")}
          class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-base-content/10 hover:text-base-content"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
        <button
          :if={@input_name && !@readonly}
          type="button"
          phx-click="ref_move"
          phx-value-id={@item.id}
          phx-value-dir="up"
          phx-target={@target}
          disabled={@index == 0}
          aria-label={gettext("Move item %{position} up", position: @index + 1)}
          class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-base-content/10 hover:text-base-content disabled:opacity-30"
        >
          <.icon name="hero-chevron-up" class="size-4" />
        </button>
        <button
          :if={@input_name && !@readonly}
          type="button"
          phx-click="ref_move"
          phx-value-id={@item.id}
          phx-value-dir="down"
          phx-target={@target}
          disabled={@index == @last}
          aria-label={gettext("Move item %{position} down", position: @index + 1)}
          class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-base-content/10 hover:text-base-content disabled:opacity-30"
        >
          <.icon name="hero-chevron-down" class="size-4" />
        </button>
        <button
          :if={!@readonly}
          type="button"
          phx-click="ref_remove"
          phx-value-id={@item.id}
          phx-target={@target}
          data-ref-remove
          aria-label={gettext("Remove %{title}", title: @item.title || gettext("Untitled"))}
          class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-error/10 hover:text-error"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </li>
    """
  end

  attr :src, :string, default: nil
  attr :slot, :boolean, required: true

  # A row's featured image (#3223), decorative: the title beside it names the
  # record, so the image adds nothing to the accessible name. A row without
  # one keeps an empty slot of the same size when another row of its list has
  # one, so the titles line up; a list where no row has one renders neither.
  defp thumb_image(assigns) do
    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      aria-hidden="true"
      loading="lazy"
      data-ref-thumb
      class="size-8 shrink-0 rounded bg-base-200 object-cover"
    />
    <span
      :if={!@src and @slot}
      aria-hidden="true"
      data-ref-thumb-placeholder
      class="size-8 shrink-0 rounded bg-base-200"
    />
    """
  end

  defp count_label(count, max) when is_integer(max),
    do: gettext("%{count} of %{max}", count: count, max: max)

  defp count_label(count, _max), do: ngettext("%{count} item", "%{count} items", count)

  defp search_placeholder(true, [_ | _]), do: gettext("Connect another…")
  defp search_placeholder(_multiple?, _items), do: gettext("Search to connect a record…")

  defp no_results_label(query) do
    if String.trim(query) == "",
      do: gettext("Nothing to connect yet."),
      else: gettext("No matches for “%{query}”.", query: String.trim(query))
  end

  defp status_label(false, _results, _more?), do: ""

  defp status_label(true, results, more?) do
    count = length(results)

    if more?,
      do: ngettext("%{count} result, more available", "%{count} results, more available", count),
      else: ngettext("%{count} result", "%{count} results", count)
  end
end
