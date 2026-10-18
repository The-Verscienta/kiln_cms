defmodule KilnCMSWeb.ContentEditor.ReverseField do
  @moduledoc """
  The content editor's **reverse field** (R4 in `docs/relationships-plan.md`):
  the other side of a `:reference` field that names one, on each record it may
  point at — "Recipes using this ingredient" on an Ingredient, for a Recipe's
  `ingredients` field.

  It lists the records connecting to this one through that field, each with
  its connection's details (the link fields, R3), ordered by title and a page
  at a time. Nothing in it belongs to the editor form: the connection is the
  *source* record's value.

  ## Editing from this side (R4b, decision D23)

  Adding, removing and moving a connection here is an edit of the **source**,
  never a bare edge: `KilnCMS.CMS.ReverseFields.connect/4` (and its
  siblings) runs the source's own update as the editor — or saves its working
  copy when it is published — so its policies, validations, version history
  and optimistic lock apply exactly as in its own editor. One click edits one
  source, so a failure (a lock conflict, a refusal, a full list) is that
  row's alone, reported on the row; the list is read again so a retry starts
  from what is there now.

    * A source the editor may not write is listed with a lock, not controls.
    * A published source's change waits in its working copy: the row says
      it goes live when that source is published, and links to it.
    * Adding uses the reference picker (`ReferencePicker`, `rows: false`,
      `notify:` this component), searching the source type as the editor.

  Reading is `KilnCMS.CMS.ReverseFields.rows/3`, as the editor's actor, so the
  both-ends read rule holds: an editor scoped away from the source type is
  not shown its records, and the count counts only what they may open.

  Rows render with the reference picker's own row
  (`KilnCMSWeb.ContentEditor.ReferencePicker.row/1`, `readonly`), so both
  sides of a relationship look the same.
  """

  use KilnCMSWeb, :live_component

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.ReverseFields
  alias KilnCMSWeb.ContentEditor.ReferencePicker

  @page_size 10

  @doc "How many rows one page shows."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:offset, 0)
     |> assign(:errors, %{})
     |> assign(:notice, nil)
     |> assign(:capacity, nil)}
  end

  # A pick (or an "Add new" record) from the add control, sent here by the
  # picker (`notify:`). Only an id: the source is read again as the editor,
  # so nothing the picker carried is trusted.
  @impl true
  def update(%{picked: {op, id}}, socket) when op in [:add, :put] and is_binary(id) do
    %{reverse: reverse, actor: actor, tenant: tenant, record: target} = socket.assigns

    socket =
      case ContentTypes.get_record(reverse.source_type, id, actor: actor, tenant: tenant) do
        {:ok, source} ->
          result = ReverseFields.connect(target, reverse, source, actor: actor, tenant: tenant)
          settle(socket, source, result, :add)

        _unreadable ->
          socket
      end

    {:ok, socket}
  end

  def update(%{picked: _other}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    # The parent re-renders the panel on every keystroke; the list only moves
    # when the record does (a save), so it is read again only then.
    stale? = Map.get(socket.assigns, :loaded) != version(assigns.record)
    socket = assign(socket, assigns)

    {:ok,
     if(stale?, do: socket |> load() |> assign(:loaded, version(assigns.record)), else: socket)}
  end

  defp version(record), do: {record.id, Map.get(record, :updated_at)}

  # One source's write, done: the list is read again either way — after a
  # success to show it, after a failure so a retry starts from the row as it
  # is now — and the outcome is said on that row alone.
  defp settle(socket, source, {:ok, _source}, op) do
    socket
    |> update(:errors, &Map.delete(&1, source.id))
    |> assign(:notice, notice(source, op))
    |> load()
  end

  defp settle(socket, source, {:error, error}, _op) do
    socket
    |> update(
      :errors,
      &Map.put(&1, source.id, error_message(error, source, socket.assigns.reverse))
    )
    |> assign(:notice, nil)
    |> load()
  end

  defp notice(%{state: :published, title: title}, _op),
    do:
      gettext(
        "Saved to the working copy of “%{title}”. It goes live when “%{title}” is published.",
        title: title || gettext("Untitled")
      )

  defp notice(%{title: title}, :add),
    do: gettext("Connected “%{title}”.", title: title || gettext("Untitled"))

  defp notice(%{title: title}, :remove),
    do: gettext("Disconnected “%{title}”.", title: title || gettext("Untitled"))

  defp notice(%{title: title}, :move),
    do: gettext("Moved this record in “%{title}”.", title: title || gettext("Untitled"))

  defp error_message(:occupied, source, reverse) do
    gettext(
      "“%{title}” already connects another record through %{field}. Change it from its own page.",
      title: source.title || gettext("Untitled"),
      field: reverse.definition.label
    )
  end

  defp error_message(error, source, _reverse) do
    cond do
      KilnCMSWeb.InlineEditing.stale_conflict?(error) ->
        gettext("This record was updated by someone else. Please reload and try again.")

      match?(%Ash.Error.Forbidden{}, error) ->
        gettext("You can't change “%{title}”.", title: source.title || gettext("Untitled"))

      match?(%Ash.Error.Invalid{}, error) ->
        Enum.map_join(error.errors, " ", &Exception.message/1)

      true ->
        gettext("Couldn't save “%{title}”.", title: source.title || gettext("Untitled"))
    end
  end

  @impl true
  def handle_event("reverse_page", %{"offset" => offset}, socket) do
    offset =
      case Integer.parse(to_string(offset)) do
        {n, ""} when n >= 0 -> n
        _other -> 0
      end

    {:noreply, socket |> assign(:offset, offset) |> load()}
  end

  # Row controls: only for a row this page shows, and only one the editor may
  # write — the write itself is authorized again, this just keeps a
  # hand-sent event from reaching a source the list never offered.
  def handle_event("reverse_" <> op, %{"id" => id} = params, socket)
      when op in ["remove", "restore", "move"] do
    case Enum.find(socket.assigns.rows, &(&1.source.id == id and &1.editable?)) do
      nil -> {:noreply, socket}
      row -> {:noreply, write(socket, row.source, op, params)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp write(socket, source, op, params) do
    %{reverse: reverse, actor: actor, tenant: tenant, record: target} = socket.assigns
    opts = [actor: actor, tenant: tenant]

    case {op, params["dir"]} do
      {"remove", _} ->
        settle(socket, source, ReverseFields.disconnect(target, reverse, source, opts), :remove)

      {"restore", _} ->
        settle(socket, source, ReverseFields.connect(target, reverse, source, opts), :add)

      {"move", dir} when dir in ["up", "down"] ->
        direction = String.to_existing_atom(dir)

        settle(
          socket,
          source,
          ReverseFields.move(target, reverse, source, direction, opts),
          :move
        )

      _other ->
        socket
    end
  end

  defp load(socket) do
    %{record: record, reverse: reverse, actor: actor, tenant: tenant, offset: offset} =
      socket.assigns

    page =
      ReverseFields.rows(record, reverse,
        actor: actor,
        tenant: tenant,
        offset: offset,
        limit: @page_size
      )

    # A page past the end (rows removed since) falls back to the last page.
    if page.rows == [] and offset > 0 and page.total > 0 do
      socket |> assign(:offset, last_offset(page.total)) |> load()
    else
      socket
      |> assign(:rows, page.rows)
      |> assign(:total, page.total)
      |> assign(:ids, page.ids)
      |> assign(:link_fields, FieldDefinition.link_fields(reverse.definition))
      |> assign(:capacity, capacity(record, reverse, actor, tenant))
    end
  end

  # `{connected, max}` when the field caps how many records may connect to
  # this one (`max_sources`, R1b), else nil. Counted from the edges — every
  # source, drafts and trashed ones included, as the cap itself counts — not
  # from the rows, which leave out what the editor may not open.
  defp capacity(record, %{definition: %{max_sources: max}} = reverse, actor, tenant)
       when is_integer(max) do
    connected =
      record.id
      |> CMS.list_references_to!(%{field: reverse.field, source_type: reverse.source_type},
        actor: actor,
        tenant: tenant,
        query: [select: [:id, :source_id]]
      )
      |> Enum.uniq_by(& &1.source_id)
      |> length()

    {connected, max}
  end

  defp capacity(_record, _reverse, _actor, _tenant), do: nil

  defp full?({connected, max}), do: connected >= max
  defp full?(nil), do: false

  defp last_offset(total), do: div(total - 1, @page_size) * @page_size

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :root,
        "reverse-field-#{assigns.reverse.source_type}-#{assigns.reverse.field}"
      )

    ~H"""
    <div
      id={@root}
      role="group"
      aria-labelledby={"#{@root}-label"}
      aria-describedby={"#{@root}-hint"}
      data-reverse-field={@reverse.name}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{@root}-label"} class="flex items-center gap-1.5 text-sm font-medium">
          <.icon name="hero-arrow-uturn-left" class="size-3.5 text-base-content/40" />
          {@reverse.label}
        </span>
        <span
          :if={@capacity}
          id={"#{@root}-capacity"}
          class={[
            "text-xs tabular-nums",
            if(full?(@capacity), do: "text-warning-ink", else: "text-base-content/60")
          ]}
        >
          {gettext("%{count} of %{max}", count: elem(@capacity, 0), max: elem(@capacity, 1))}
        </span>
        <span :if={!@capacity and @total > 0} class="text-xs tabular-nums text-base-content/60">
          {ngettext("%{count} connected", "%{count} connected", @total)}
        </span>
      </div>
      <p id={"#{@root}-hint"} class="mb-1.5 text-xs text-base-content/60">
        {gettext("%{type} records that connect to this one through their %{field} field.",
          type: @reverse.source_label,
          field: @reverse.definition.label
        )}
      </p>

      <p :if={@notice} id={"#{@root}-notice"} role="status" class="mb-1.5 text-xs text-success-ink">
        {@notice}
      </p>

      <ol
        :if={@rows != []}
        id={"#{@root}-items"}
        aria-label={@reverse.label}
        class="divide-y divide-base-content/10 overflow-hidden rounded-md border border-base-content/10"
      >
        <ReferencePicker.row
          :for={row <- @rows}
          id={"#{@root}-#{row.source.id}"}
          item={item(row, @reverse)}
          readonly
        >
          <:extra>
            <.connection_details
              id={"#{@root}-#{row.source.id}-details"}
              fields={@link_fields}
              values={row.link && row.link.metadata}
              position={@reverse.definition.multiple && row.link && row.link.position}
            />
            <.pending_note
              :if={row.pending}
              id={"#{@root}-#{row.source.id}-pending"}
              pending={row.pending}
              source={row.source}
              href={item(row, @reverse).href}
            />
            <p
              :if={@errors[row.source.id]}
              id={"#{@root}-#{row.source.id}-error"}
              role="alert"
              class="mt-1 flex items-start gap-1 text-xs text-error"
            >
              <.icon name="hero-exclamation-circle" class="mt-px size-3.5 shrink-0" />
              {@errors[row.source.id]}
            </p>
          </:extra>
          <:actions>
            <.row_actions
              row={row}
              root={@root}
              multiple={@reverse.definition.multiple}
              target={@myself}
            />
          </:actions>
        </ReferencePicker.row>
      </ol>

      <p :if={@rows == []} class="text-sm text-base-content/60">
        {gettext("Nothing connects to this record yet.")}
      </p>

      <p
        :if={@actor && full?(@capacity)}
        id={"#{@root}-full"}
        class="mt-2 flex items-center gap-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-no-symbol" class="size-3.5 shrink-0" />
        {gettext("Full — %{count} of %{max} connected. Remove one to connect another.",
          count: elem(@capacity, 0),
          max: elem(@capacity, 1)
        )}
      </p>

      <div :if={@actor && not full?(@capacity)} class="mt-2">
        <.live_component
          module={ReferencePicker}
          id={"#{@root}-add"}
          definition={picker_definition(@reverse)}
          name={"_kiln_reverse[#{@reverse.source_type}][#{@reverse.field}]"}
          value={Enum.map(@ids, &%{"id" => &1})}
          errors={[]}
          rows={false}
          notify={{__MODULE__, @id}}
          placeholder={gettext("Connect a %{type}…", type: @reverse.source_label)}
          actor={@actor}
          tenant={@tenant}
        />
      </div>

      <nav
        :if={@total > length(@rows)}
        aria-label={gettext("%{field} pages", field: @reverse.label)}
        class="mt-1.5 flex items-center justify-between gap-2 text-xs text-base-content/60"
      >
        <span class="tabular-nums">
          {gettext("%{first}–%{last} of %{total}",
            first: @offset + 1,
            last: @offset + length(@rows),
            total: @total
          )}
        </span>
        <span class="flex items-center gap-1">
          <button
            type="button"
            phx-click="reverse_page"
            phx-value-offset={max(@offset - page_size(), 0)}
            phx-target={@myself}
            disabled={@offset == 0}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-chevron-left" class="size-3.5" />
            {gettext("Previous")}
          </button>
          <button
            type="button"
            phx-click="reverse_page"
            phx-value-offset={@offset + page_size()}
            phx-target={@myself}
            disabled={@offset + length(@rows) >= @total}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Next")}
            <.icon name="hero-chevron-right" class="size-3.5" />
          </button>
        </span>
      </nav>
    </div>
    """
  end

  # The add control searches the source type as if it were a list field of
  # this record: one type, any number, nothing to show of its own.
  defp picker_definition(reverse) do
    %FieldDefinition{
      name: "reverse-#{reverse.source_type}-#{reverse.field}",
      label: gettext("Connect a %{type}", type: reverse.source_label),
      field_type: :reference,
      target_type: reverse.source_type,
      target_types: [],
      multiple: true,
      link_fields: []
    }
  end

  attr :row, :map, required: true
  attr :root, :string, required: true
  attr :multiple, :boolean, required: true
  attr :target, :any, required: true

  # Remove and move — or "put back" for a removal still in a working copy — on
  # a source the editor may write; a lock on one they may not.
  defp row_actions(%{row: %{editable?: false}} = assigns) do
    ~H"""
    <span
      id={"#{@root}-#{@row.source.id}-locked"}
      title={gettext("You can't change this record, so its connection is read-only here.")}
      class="p-0.5 text-base-content/40"
    >
      <.icon name="hero-lock-closed" class="size-4" />
    </span>
    """
  end

  defp row_actions(%{row: %{pending: :remove}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="reverse_restore"
      phx-value-id={@row.source.id}
      phx-target={@target}
      class="btn btn-ghost btn-sm"
    >
      {gettext("Put back")}
    </button>
    """
  end

  defp row_actions(assigns) do
    assigns =
      assign(assigns, :position, if(assigns.row.link, do: assigns.row.link.position, else: 0))

    ~H"""
    <button
      :if={@multiple}
      type="button"
      phx-click="reverse_move"
      phx-value-id={@row.source.id}
      phx-value-dir="up"
      phx-target={@target}
      disabled={@position == 0}
      aria-label={gettext("Move up in %{title}", title: @row.source.title || gettext("Untitled"))}
      class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-base-content/10 hover:text-base-content disabled:opacity-30"
    >
      <.icon name="hero-chevron-up" class="size-4" />
    </button>
    <button
      :if={@multiple}
      type="button"
      phx-click="reverse_move"
      phx-value-id={@row.source.id}
      phx-value-dir="down"
      phx-target={@target}
      disabled={@position >= @row.count - 1}
      aria-label={gettext("Move down in %{title}", title: @row.source.title || gettext("Untitled"))}
      class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-base-content/10 hover:text-base-content disabled:opacity-30"
    >
      <.icon name="hero-chevron-down" class="size-4" />
    </button>
    <button
      type="button"
      phx-click="reverse_remove"
      phx-value-id={@row.source.id}
      phx-target={@target}
      data-ref-remove
      aria-label={gettext("Disconnect %{title}", title: @row.source.title || gettext("Untitled"))}
      class="rounded p-0.5 text-base-content/60 transition-colors hover:bg-error/10 hover:text-error"
    >
      <.icon name="hero-x-mark" class="size-4" />
    </button>
    """
  end

  attr :id, :string, required: true
  attr :pending, :atom, required: true
  attr :source, :map, required: true
  attr :href, :string, required: true

  # A change held in a published source's working copy (D23): not live yet,
  # and the row says so, with the way to the page that publishes it.
  defp pending_note(assigns) do
    ~H"""
    <p id={@id} class="mt-1 flex flex-wrap items-center gap-1 text-xs text-warning-ink">
      <.icon name="hero-clock" class="size-3.5" />
      <span>
        {pending_label(@pending)} · {gettext("goes live when “%{title}” is published",
          title: @source.title || gettext("Untitled")
        )}
      </span>
      <.link navigate={@href} class="link font-medium">{gettext("Open it")}</.link>
    </p>
    """
  end

  defp pending_label(:add), do: gettext("Connection pending")
  defp pending_label(:remove), do: gettext("Removal pending")
  defp pending_label(:move), do: gettext("New position pending")

  defp item(%{source: source}, reverse) do
    %{
      id: source.id,
      title: source.title,
      state: source.state,
      type_label: reverse.source_label,
      href: ~p"/editor/content/#{reverse.source_type}/#{source.id}"
    }
  end

  attr :id, :string, required: true
  attr :fields, :list, required: true
  attr :values, :map, required: true
  attr :position, :any, default: nil

  # The connection's details as text: its link-field values (R3) in the
  # field's order, and — for a list — this record's place in the source's list.
  defp connection_details(assigns) do
    assigns =
      assign(
        assigns,
        :shown,
        for(
          field <- assigns.fields,
          (value = Map.get(assigns.values || %{}, field.name)) not in [nil, ""],
          do: {field, value}
        )
      )

    ~H"""
    <p
      :if={@shown != [] or is_integer(@position)}
      id={@id}
      class="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-base-content/70"
    >
      <span
        :if={is_integer(@position)}
        class="rounded bg-base-200 px-1.5 py-0.5 tabular-nums"
      >
        {gettext("No. %{position} in its list", position: @position + 1)}
      </span>
      <span :for={{field, value} <- @shown} class="rounded bg-base-200 px-1.5 py-0.5">
        <span class="text-base-content/50">{field.label}:</span> {format(value)}
      </span>
    </p>
    """
  end

  defp format(true), do: gettext("Yes")
  defp format(false), do: gettext("No")
  defp format(value), do: to_string(value)
end
