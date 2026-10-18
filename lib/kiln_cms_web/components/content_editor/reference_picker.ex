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

  ## Seams for later workstreams

    * `row/1` is public and takes `readonly`, so the reverse list (R4) can
      render the same row without the controls.
    * The `:row_extra` slot renders inside each row, after the title (and the
      link inputs), with the row's item.
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

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMSWeb.ContentEditor.ReferenceValues

  @page_size 20

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
     |> assign(:creating, nil)
     |> assign(:announcement, "")}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:locked, fn -> false end)
      |> assign_new(:row_extra, fn -> [] end)
      |> assign_new(:link_name, fn -> link_name(assigns.name) end)
      |> assign(:link_fields, FieldDefinition.link_fields(assigns.definition))
      |> assign(:links, ReferenceValues.links(assigns.value, assigns.definition))

    ids =
      assigns.value
      |> ReferenceValues.keys(ReferenceValues.polymorphic?(assigns.definition))
      |> Enum.uniq()

    socket =
      if ids == socket.assigns.ids,
        do: socket,
        else: socket |> assign(:ids, ids) |> resolve(ids)

    socket =
      if socket.assigns.creatable == nil,
        do: assign(socket, :creatable, creatable(socket.assigns)),
        else: socket

    {:ok, socket |> assign(:items, items(socket.assigns)) |> assign_capacity()}
  end

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
    query = queries |> Map.get(socket.assigns.definition.name, "") |> to_string()

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
    case {socket.assigns.creating, Map.get(forms, socket.assigns.definition.name)} do
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
      attrs = %{title: title, custom_fields: new_custom_fields(entry.fields, params)}

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
  defp new_custom_fields(fields, params) do
    supplied = Map.get(params, "custom_fields", %{})
    supplied = if is_map(supplied), do: supplied, else: %{}

    Map.new(fields, &{&1.name, Map.get(supplied, &1.name, "")})
  end

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
    definition
    |> target_types(tenant)
    |> Enum.flat_map(fn ct ->
      with true <- ContentTypes.can_create?(ct, actor, %{}, tenant: tenant),
           {:ok, fields} <- form_fields(ct, actor, tenant) do
        [%{key: to_string(ct.type), ct: ct, label: ct.label, fields: fields}]
      else
        _not_here -> []
      end
    end)
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
    exclude = if multiple?(socket), do: socket.assigns.ids, else: []

    case target_types(definition, tenant) do
      [] ->
        socket |> assign(:results, []) |> assign(:more?, false)

      cts ->
        rows = search_rows(socket, cts, query, exclude, offset)
        {page, rest} = Enum.split(rows, @page_size)
        page = Enum.map(page, fn {record, ct} -> to_item(record, ct, definition) end)
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
    |> sort_merged(query)
    |> Enum.drop(offset)
    |> Enum.take(@page_size + 1)
  end

  defp read_type(socket, ct, query, exclude, limit, offset) do
    %{definition: definition, tenant: tenant, actor: actor} = socket.assigns

    ContentTypes.list!(ct,
      actor: actor,
      tenant: tenant,
      query:
        search_filters(query, excluded_ids(exclude, ct, definition)) ++
          [
            select: [:id, :title, :state, :slug, :updated_at],
            sort: search_sort(query),
            limit: limit,
            offset: offset
          ]
    )
  end

  defp sort_merged(rows, query) do
    if String.trim(query) == "",
      do: Enum.sort(rows, &newer_first?/2),
      else: Enum.sort_by(rows, fn {record, _ct} -> {record.title || "", record.id} end)
  end

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

  defp search_sort(query) do
    if String.trim(query) == "", do: [updated_at: :desc, id: :asc], else: [title: :asc, id: :asc]
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
          query: [filter: [id: [in: missing]], select: [:id, :title, :state, :slug]]
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
      title: record.title,
      state: record.state,
      type: ct.type,
      type_label: ct.label,
      href: ~p"/editor/content/#{type}/#{record.id}"
    }
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
          href: nil
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
      |> assign(:root, "custom-field-#{assigns.definition.name}")
      |> assign(:last, length(assigns.items) - 1)

    ~H"""
    <div
      id={@root}
      phx-hook="ReferencePicker"
      phx-target={@myself}
      role="group"
      aria-labelledby={"#{@root}-label"}
      aria-describedby={@errors != [] && "#{@root}-errors"}
      data-reference-picker={@definition.name}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{@root}-label"} class="text-sm font-medium">{@definition.label}</span>
        <span :if={@multiple? and @items != []} class="text-xs tabular-nums text-base-content/60">
          {count_label(length(@items), @definition.max_items)}
        </span>
      </div>

      <input :if={@multiple?} type="hidden" name={"#{@name}[]"} value="" />
      <input
        :if={not @multiple?}
        type="hidden"
        name={@name}
        value={List.first(@ids) || ""}
      />

      <ol
        :if={@items != []}
        id={"#{@root}-items"}
        data-ref-items
        aria-label={gettext("Connected records")}
        class="divide-y divide-base-content/10 overflow-hidden rounded-md border border-base-content/10"
      >
        <.row
          :for={{item, index} <- Enum.with_index(@items)}
          id={"cf-ref-#{@definition.name}-#{String.replace(item.id, ":", "-")}"}
          item={item}
          index={index}
          last={@last}
          input_name={@multiple? && "#{@name}[]"}
          sortable={@multiple? and not @locked and @last > 0}
          readonly={@locked}
          target={@myself}
        >
          <:extra :if={@link_fields != []}>
            <.link_inputs
              id={"cf-ref-#{@definition.name}-#{String.replace(item.id, ":", "-")}-link"}
              fields={@link_fields}
              name={"#{@link_name}[#{item.id}]"}
              values={Map.get(@links, item.id, %{})}
              title={item.title}
              readonly={@locked}
            />
          </:extra>
          <:extra :for={extra <- @row_extra}>{render_slot(extra, item)}</:extra>
        </.row>
      </ol>

      <p :if={@items == [] and not @searchable?} class="text-sm text-base-content/60">
        {gettext("Nothing connected yet.")}
      </p>

      <div
        :if={@searchable?}
        class={["relative", @items != [] && "mt-2"]}
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
            name={"_kiln_ref_q[#{@definition.name}]"}
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
            placeholder={search_placeholder(@multiple?, @items)}
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
            data-ref-option
            phx-click="ref_pick"
            phx-value-id={result.id}
            phx-target={@myself}
            class="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-sm transition-colors hover:bg-base-200 aria-selected:bg-primary/10"
          >
            <span class="min-w-0 flex-1 truncate">{result.title || gettext("Untitled")}</span>
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
          <li :if={@results == []} role="presentation" class="px-3 py-2 text-sm text-base-content/60">
            {no_results_label(@query)}
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
        field={@definition.name}
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
      <.new_field
        :for={definition <- @entry.fields}
        id={"#{@form_id}-cf-#{definition.name}"}
        definition={definition}
        name={"#{@prefix}[custom_fields][#{definition.name}]"}
        value={get_in(@creating.params, ["custom_fields", definition.name])}
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
  attr :definition, :map, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :target, :any, required: true

  defp new_field(%{definition: %{field_type: :boolean}} = assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@value == "true"}
        phx-change="ref_new_change"
        phx-target={@target}
        class="size-4 rounded border-base-content/30"
      />
      <label for={@id} class="text-xs font-medium">{@definition.label}</label>
    </div>
    """
  end

  defp new_field(%{definition: %{field_type: :select}} = assigns) do
    ~H"""
    <div>
      <label for={@id} class="mb-1 block text-xs font-medium">{@definition.label}</label>
      <select
        id={@id}
        name={@name}
        phx-change="ref_new_change"
        phx-target={@target}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={option <- @definition.options} value={option} selected={@value == option}>
          {option}
        </option>
      </select>
    </div>
    """
  end

  defp new_field(%{definition: %{field_type: :text}} = assigns) do
    ~H"""
    <div>
      <label for={@id} class="mb-1 block text-xs font-medium">{@definition.label}</label>
      <textarea
        id={@id}
        name={@name}
        rows="3"
        phx-change="ref_new_change"
        phx-target={@target}
        class="field-input min-h-16"
      >{@value}</textarea>
    </div>
    """
  end

  defp new_field(assigns) do
    assigns = assign(assigns, :type, input_type(assigns.definition.field_type))

    ~H"""
    <div>
      <label for={@id} class="mb-1 block text-xs font-medium">{@definition.label}</label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        step={@definition.field_type == :float && "any"}
        autocomplete="off"
        phx-change="ref_new_change"
        phx-target={@target}
        class="field-input"
      />
    </div>
    """
  end

  defp input_type(:integer), do: "number"
  defp input_type(:float), do: "number"
  defp input_type(:date), do: "date"
  defp input_type(:datetime), do: "datetime-local"
  defp input_type(:url), do: "url"
  defp input_type(_string), do: "text"

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
          {option}
        </option>
      </select>
    </div>
    """
  end

  defp link_input(assigns) do
    assigns = assign(assigns, :type, input_type(assigns.field.field_type))

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
  attr :item, :map, required: true, doc: "`id`, `title`, `state`, `type_label`, `href`"
  attr :index, :integer, default: 0
  attr :last, :integer, default: 0
  attr :input_name, :any, default: nil, doc: "the `name[]` a list row submits its id under"
  attr :sortable, :boolean, default: false
  attr :readonly, :boolean, default: false
  attr :target, :any, default: nil
  slot :extra, doc: "rendered after the title — per-link inputs (R3)"

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
