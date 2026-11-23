defmodule KilnCMSWeb.ContentEditor.ReferenceInline do
  @moduledoc """
  The **record card** on a connected row of a reference field whose
  `edit_inline` option is on (#2283, `docs/plans/inline-reference-editing-plan.md`):
  a live component that edits the related record from the parent's page and
  saves it **on its own**, as its own write, under its own authorization.

  Nothing here touches the parent: the card's *Save* runs the child's `:update`
  (a draft) or `:save_working_copy` (a published record, whose live text does
  not move until its own *Publish changes*), as the actor, in the parent's
  tenant, and then re-reads the record. The parent's Save does not save the
  card (the plan's third step adds that cascade) and the card never connects,
  disconnects or reorders anything.

  The rules the card keeps:

    * **A card is offered only for a record the actor may write**
      (`KilnCMS.CMS.ContentTypes.can_write?/4`: its working copy when it is
      published, the row otherwise), in the parent's tenant. A record the actor
      cannot read is the row's *Unavailable* state and has no card; one they
      can read but not write has a row and no card. The parent record itself
      never gets a card on its own field.
    * **The server decides on every event.** The picker only mounts a card for a
      row key that is one of the field's current values and that it decided the
      actor may write. The card re-reads the record as the actor on opening and
      on every save, so a forged event for an unreadable, trashed, cross-tenant,
      read-only or unconnected record writes nothing, and a record that
      changed since the card read it (another editor's save, a publish, an
      unpublish, a trash) is refused as *changed by someone else*.
    * **A server-side whitelist, not just a UI.** A save takes only the keys of
      the card's own editable set (`plain_types/0` fields the actor's grant
      allows, minus read-hidden, computed, dynamic-default and, on a
      translation, shared fields; the title when it is writable and not
      derived), read from the card's own slice of the params. A hand-posted
      media, reference or computed value is ignored. The child's own
      `EnforceCustomFieldGrants`, validations and policies still run on top.
    * **Read grants first.** A private field the actor's read grant hides
      (`KilnCMS.CMS.HiddenFields`) is not rendered, and its stored value is
      never used to decide a condition.
    * **Narrow by construction.** Only the field types the "Add new" form
      renders; no nested picker, no recursion. The rest is a link to the full
      editor.
    * **Errors stay on the card.** The child's validation errors render under
      the child's inputs; the parent's errors are untouched.

  The card's inputs sit inside the editor's `<form>`, so they are named under
  `_kiln_inline[<field>][<row key>]`, carry their own `phx-change`, and are
  stripped from the parent's params (`ReferenceValues.normalize/2`).
  """
  use KilnCMSWeb, :live_component

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.HiddenFields
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMSWeb.ContentEditor.PlainField

  # The field types the card shows: those the "Add new" form renders.
  @plain_types [:string, :text, :integer, :float, :boolean, :date, :datetime, :url, :select]

  @doc "The field types a card shows (the ones the \"Add new\" form renders)."
  @spec plain_types() :: [atom()]
  def plain_types, do: @plain_types

  @doc "The most cards open at once on one field."
  @spec max_open() :: pos_integer()
  def max_open, do: 10

  @doc """
  Which of `items` (the picker's connected rows, with the `:type` and
  `:record_id` of the record each points at) the actor may write, as
  `%{row key => true | false}`. A row whose record cannot be read is `false`.
  Fails closed: any error reads as `false`.
  """
  @spec writable(%{optional(String.t()) => map()}, [map()], term(), term()) ::
          %{optional(String.t()) => boolean()}
  def writable(cts, items, actor, tenant) do
    items
    |> Enum.filter(&(&1.state != nil))
    |> Enum.group_by(&to_string(&1.type))
    |> Enum.flat_map(fn {type, rows} ->
      case Map.get(cts, type) do
        nil -> Enum.map(rows, &{&1.id, false})
        ct -> probe(ct, rows, actor, tenant)
      end
    end)
    |> Map.new()
  end

  defp probe(ct, rows, actor, tenant) do
    ids = Enum.map(rows, & &1.record_id)

    records =
      ct
      |> ContentTypes.list!(actor: actor, tenant: tenant, query: [filter: [id: [in: ids]]])
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn row ->
      {row.id,
       match?(%{}, records[row.record_id]) and
         can_write?(ct, records[row.record_id], actor, tenant)}
    end)
  rescue
    # A failed probe decides nothing, so the rows are probed again next time
    # instead of staying "not writable" after a transient error.
    _error -> []
  end

  defp can_write?(ct, record, actor, tenant) do
    ContentTypes.can_write?(ct, record, actor, tenant: tenant) == true
  rescue
    _error -> false
  end

  defp read(ct, id, actor, tenant) do
    case ContentTypes.list!(ct,
           actor: actor,
           tenant: tenant,
           query: [filter: [id: id], limit: 1]
         ) do
      [record] -> {:ok, record}
      _none -> :error
    end
  rescue
    _error -> :error
  end

  # ── the component ────────────────────────────────────────────────────────

  @impl true
  def mount(socket), do: {:ok, socket |> assign(:loaded?, false) |> assign(:dirty?, false)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Opened once; the picker's later renders only refresh the row's facts.
    socket = if socket.assigns.loaded?, do: socket, else: open(socket)
    {:ok, socket}
  end

  defp open(socket) do
    %{ct: ct, record_id: id, actor: actor, tenant: tenant} = socket.assigns

    with {:ok, record} <- read(ct, id, actor, tenant),
         true <- can_write?(ct, record, actor, tenant) do
      socket |> assign(:loaded?, true) |> seed(record, :clean)
    else
      _refused -> socket |> assign(:loaded?, true) |> refuse()
    end
  end

  # (Re)seeds every assign from `record`, a fresh read.
  defp seed(socket, record, status) do
    %{ct: ct, actor: actor, tenant: tenant} = socket.assigns
    view = WorkingCopy.view(record)
    hidden = HiddenFields.names(actor, record, tenant)
    stored = Map.new(view.custom_fields || %{}, fn {k, v} -> {to_string(k), v} end)
    grant = Scoping.field_grant(actor, tenant, to_string(ct.type))
    all = all_definitions(ct, actor, tenant)

    shown =
      for definition <- all,
          FieldDefinition.top_level?(definition),
          definition.field_type in @plain_types,
          definition.name not in hidden,
          is_nil(Map.get(definition, :default_source)) do
        %{
          definition: definition,
          editable?:
            FieldAccess.writable?(grant, [definition.name]) and
              not (definition.localization == :shared and not FieldLocalization.source?(record))
        }
      end

    title_editable? =
      (is_nil(grant) or "title" in grant) and ct.title_template in [nil, ""]

    values = %{
      "title" => view.title,
      "custom_fields" =>
        Map.new(shown, fn %{definition: d} ->
          {d.name, input_value(d, Map.get(stored, d.name))}
        end)
    }

    socket
    |> assign(:record, record)
    |> assign(:shown, shown)
    |> assign(:hidden, hidden)
    |> assign(:stored, Map.drop(stored, hidden))
    |> assign(:title_editable?, title_editable?)
    |> assign(:original, values)
    |> assign(:values, values)
    |> assign(:errors, %{})
    |> assign(:status, status)
    |> assign(:more?, more?(all, hidden))
    |> notify_dirty(false)
  end

  defp all_definitions(%{source: :dynamic, definition: definition}, actor, tenant),
    do: CMS.field_definitions_for_definition!(definition.id, actor: actor, tenant: tenant)

  defp all_definitions(ct, actor, tenant),
    do: CMS.field_definitions_for!(ct.type, actor: actor, tenant: tenant)

  # Whether the record carries fields the card does not show.
  defp more?(all, hidden) do
    Enum.any?(all, fn definition ->
      FieldDefinition.top_level?(definition) and definition.name not in hidden and
        (definition.field_type not in @plain_types or
           not is_nil(Map.get(definition, :default_source)))
    end)
  end

  # What an input shows for a stored value (always text, as the inputs post).
  defp input_value(_definition, nil), do: ""

  defp input_value(%{field_type: :boolean}, value),
    do: to_string(value == true or value == "true")

  defp input_value(%{field_type: :datetime}, value) when is_binary(value),
    do: String.slice(value, 0, 16)

  defp input_value(_definition, value) when is_binary(value) or is_number(value),
    do: to_string(value)

  defp input_value(_definition, _value), do: ""

  # ── events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("change", params, socket) do
    with true <- editing?(socket),
         %{} = slice <- slice(params, socket) do
      values = merge_values(socket, slice)

      {:noreply,
       socket
       |> assign(:values, values)
       |> assign(:errors, %{})
       |> assign(:status, if(values == socket.assigns.original, do: :clean, else: :dirty))
       |> sync_dirty()}
    else
      _ignored -> {:noreply, socket}
    end
  end

  # A click carries no form data: the card saves what its own change events
  # already put in `values`, which only ever holds the editable set.
  def handle_event("save", _params, socket),
    do: if(editing?(socket), do: {:noreply, save(socket)}, else: {:noreply, socket})

  def handle_event("discard", _params, socket) do
    if editing?(socket) do
      {:noreply,
       socket
       |> assign(:values, socket.assigns.original)
       |> assign(:errors, %{})
       |> assign(:status, :clean)
       |> sync_dirty()}
    else
      {:noreply, socket}
    end
  end

  # The card read the record before someone else changed it: drop the draft
  # and read it again.
  def handle_event("reload", _params, socket) do
    if socket.assigns[:connected?] == false or socket.assigns.status == :refused,
      do: {:noreply, socket},
      else: {:noreply, open(assign(socket, :loaded?, false))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # An editing card is one that is open, loaded and still connected.
  defp editing?(socket) do
    socket.assigns.loaded? and socket.assigns.status not in [:refused, :stale] and
      socket.assigns.connected? and socket.assigns.locked? != true
  end

  # The card's own slice of the posted form: `_kiln_inline[<field>][<key>]`,
  # nothing else.
  defp slice(params, %{assigns: %{field: field, key: key}}) do
    case params do
      %{"_kiln_inline" => %{^field => %{^key => %{} = slice}}} -> slice
      _other -> nil
    end
  end

  # Only the card's own editable set is taken from the slice; every other key
  # the client posted is dropped.
  defp merge_values(socket, slice) do
    %{values: values, shown: shown, title_editable?: title_editable?} = socket.assigns
    posted = if is_map(slice["custom_fields"]), do: slice["custom_fields"], else: %{}

    cf =
      Enum.reduce(shown, values["custom_fields"], fn
        %{definition: d, editable?: true}, acc ->
          case Map.get(posted, d.name) do
            value when is_binary(value) -> Map.put(acc, d.name, value)
            _absent -> acc
          end

        _readonly, acc ->
          acc
      end)

    title =
      case slice["title"] do
        value when is_binary(value) and title_editable? -> value
        _other -> values["title"]
      end

    %{"title" => title, "custom_fields" => cf}
  end

  # What a save writes: the changed keys of the editable set that are not
  # hidden by a condition.
  defp changes(socket) do
    %{values: values, original: original, shown: shown} = socket.assigns
    state = effective(socket)

    cf =
      for %{definition: d, editable?: true} <- shown,
          not state[d.name].hidden?,
          values["custom_fields"][d.name] != original["custom_fields"][d.name],
          into: %{},
          do: {d.name, values["custom_fields"][d.name]}

    title =
      if socket.assigns.title_editable? and values["title"] != original["title"],
        do: values["title"]

    {title, cf}
  end

  defp save(socket) do
    {title, cf} = changes(socket)

    cond do
      is_nil(title) and cf == %{} ->
        socket |> assign(:status, :clean) |> sync_dirty()

      is_binary(title) and String.trim(title) == "" ->
        socket
        |> assign(:errors, %{"title" => [gettext("Give it a title.")]})
        |> failed()

      true ->
        guarded_write(socket, title, cf)
    end
  end

  # The record as it is now, as the actor: gone, trashed, unreadable, not
  # writable, or moved on since the card read it.
  defp guarded_write(socket, title, cf) do
    %{ct: ct, record: held, actor: actor, tenant: tenant} = socket.assigns

    case read(ct, held.id, actor, tenant) do
      {:ok, current} -> judge(socket, current, title, cf)
      :error -> refuse(socket)
    end
  end

  defp judge(socket, current, title, cf) do
    %{ct: ct, record: held, actor: actor, tenant: tenant} = socket.assigns

    cond do
      not can_write?(ct, current, actor, tenant) ->
        refuse(socket)

      current.lock_version != held.lock_version or current.state != held.state ->
        assign(socket, :status, :stale)

      true ->
        write(socket, held, title, cf)
    end
  end

  defp write(socket, record, title, cf) do
    %{ct: ct, actor: actor, tenant: tenant} = socket.assigns
    opts = [actor: actor, tenant: tenant]

    result =
      if record.state == :published do
        # A published record's title travels as `working_title`; the live
        # title does not move until the record's own "Publish changes".
        attrs = if title, do: %{working_title: title}, else: %{}
        attrs = if cf == %{}, do: attrs, else: Map.put(attrs, :fields, %{"custom_fields" => cf})
        ContentTypes.save_working_copy(ct, record, attrs, opts)
      else
        attrs = if title, do: %{title: title}, else: %{}
        attrs = if cf == %{}, do: attrs, else: Map.put(attrs, :custom_fields, cf)

        # Workflow writes keep `lock_version`, so a record published since the
        # card read it would pass the lock; the state is checked with it.
        ContentTypes.update(
          ct,
          record,
          attrs,
          opts ++ [context: %{kiln_if_match: [{record.lock_version, to_string(record.state)}]}]
        )
      end

    case result do
      {:ok, _saved} -> saved(socket, record)
      {:error, error} -> rejected(socket, error)
    end
  rescue
    error in [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Unknown] ->
      rejected(socket, error)
  end

  defp saved(socket, before) do
    %{ct: ct, actor: actor, tenant: tenant} = socket.assigns

    case read(ct, before.id, actor, tenant) do
      {:ok, record} ->
        status =
          if record.state == :published and WorkingCopy.pending?(record),
            do: :saved_copy,
            else: :saved

        socket = seed(socket, record, status)
        notify_saved(socket, record)
        socket

      # The write committed; only the re-read failed. Say saved.
      :error ->
        socket
        |> assign(:status, :saved)
        |> assign(:original, socket.assigns.values)
        |> notify_dirty(false)
    end
  end

  defp rejected(socket, error) do
    errors = List.wrap(Map.get(error, :errors, [error]))

    cond do
      Enum.any?(errors, &stale?/1) ->
        assign(socket, :status, :stale)

      Enum.any?(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1)) or
          match?(%Ash.Error.Forbidden{}, error) ->
        socket
        |> assign(:errors, %{base: [gettext("You can't change this record.")]})
        |> failed()

      true ->
        socket
        |> assign(:errors, sort_errors(errors, socket.assigns.shown, socket.assigns.hidden))
        |> failed()
    end
  end

  # The record can no longer be written here: the card says so and holds no
  # unsaved state, so the row's toggle can close it.
  defp refuse(socket), do: socket |> assign(:status, :refused) |> notify_dirty(false)

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%KilnCMS.CMS.Errors.PreconditionFailed{}), do: true
  defp stale?(_other), do: false

  # Each error under the input it concerns; the rest at the card level.
  defp sort_errors(errors, shown, hidden) do
    names = Enum.map(shown, & &1.definition.name)

    Enum.reduce(errors, %{}, fn error, acc ->
      {key, message} = describe(error, names, hidden)
      Map.update(acc, key, [message], &(&1 ++ [message]))
    end)
  end

  # Under the input the error concerns, else at the card level. An error
  # about a field the actor may not read says nothing about it.
  defp describe(%{field: :custom_fields, value: name} = error, names, hidden)
       when is_binary(name) do
    cond do
      name in hidden -> {:base, gettext("The record could not be saved.")}
      name in names -> {name, text(error)}
      true -> {:base, text(error)}
    end
  end

  defp describe(%{field: field} = error, _names, _hidden) when field in [:title, :working_title],
    do: {"title", text(error)}

  defp describe(error, _names, _hidden), do: {:base, text(error)}

  defp text(error),
    do: error |> Exception.message() |> String.replace_prefix("(working copy) ", "")

  defp failed(socket) do
    socket
    |> assign(:status, :error)
    |> push_event("inline_focus", %{id: first_invalid_id(socket)})
  end

  defp first_invalid_id(socket) do
    errors = socket.assigns.errors
    dom = socket.assigns.dom_id

    cond do
      Map.has_key?(errors, "title") ->
        "#{dom}-title"

      name = Enum.find(socket.assigns.shown, &Map.has_key?(errors, &1.definition.name)) ->
        "#{dom}-f-#{name.definition.name}"

      true ->
        "#{dom}-card"
    end
  end

  # ── dirty state, for the picker (and the parent in the next step) ────────

  defp sync_dirty(socket), do: notify_dirty(socket, socket.assigns.status == :dirty)

  defp notify_dirty(socket, dirty?) do
    if socket.assigns[:dirty?] == dirty? do
      socket
    else
      send_update(KilnCMSWeb.ContentEditor.ReferencePicker,
        id: socket.assigns.picker_id,
        inline_event: {:dirty, socket.assigns.key, dirty?}
      )

      assign(socket, :dirty?, dirty?)
    end
  end

  # A saved draft carries its new title back to the row it sits under.
  defp notify_saved(socket, record) do
    send_update(KilnCMSWeb.ContentEditor.ReferencePicker,
      id: socket.assigns.picker_id,
      inline_event: {:saved, socket.assigns.key, record.state, record.title}
    )
  end

  # ── conditions ───────────────────────────────────────────────────────────

  # `hidden?`/`required?` per shown field, over the stored values of the
  # fields the card cannot change merged with what the card holds. A rule that
  # reads a field the actor cannot read is not guessed: the field shows and
  # the child's own validation decides on save.
  defp effective(socket) do
    %{shown: shown, stored: stored, values: values, hidden: hidden} = socket.assigns
    definitions = Enum.map(shown, & &1.definition)
    merged = Map.merge(stored, values["custom_fields"])

    Map.new(definitions, fn definition ->
      references =
        Conditions.references(Map.get(definition, :visible_when)) ++
          Conditions.references(Map.get(definition, :required_when))

      if Enum.any?(references, &(&1 in hidden)) do
        {definition.name, %{hidden?: false, required?: false}}
      else
        {definition.name, Map.fetch!(Conditions.effective([definition], merged), definition.name)}
      end
    end)
  end

  # ── rendering ────────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :open?, :boolean, default: false
  attr :target, :any, required: true

  @doc "The disclosure button of a row; the card renders under it."
  def toggle(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@id}-toggle"}
      phx-click="inline_toggle"
      phx-value-id={@item.id}
      phx-target={@target}
      aria-expanded={to_string(@open?)}
      aria-controls={@open? && "#{@id}-card"}
      aria-label={
        if @open?,
          do: gettext("Hide the record: %{title}", title: @item.title || gettext("Untitled")),
          else: gettext("Edit the record: %{title}", title: @item.title || gettext("Untitled"))
      }
      data-inline-toggle
      class="mt-1 inline-flex items-center gap-1 rounded text-xs font-medium text-primary-ink transition-colors hover:underline"
    >
      <.icon
        name={if @open?, do: "hero-chevron-down", else: "hero-chevron-right"}
        class="size-3.5"
      />
      <span aria-hidden="true">
        {if @open?, do: gettext("Hide the record"), else: gettext("Edit the record")}
      </span>
    </button>
    """
  end

  @impl true
  def render(%{status: :refused} = assigns) do
    ~H"""
    <div>
      <p id={"#{@dom_id}-refused"} role="status" class="mt-2 text-xs text-warning-ink">
        {gettext(
          "This record can no longer be opened here. It may have been deleted or its permissions changed."
        )}
      </p>
    </div>
    """
  end

  def render(assigns) do
    state = effective(assigns |> then(&%{assigns: &1}))
    prefix = "_kiln_inline[#{assigns.field}][#{assigns.key}]"
    record = assigns.record
    view = WorkingCopy.view(record)

    assigns =
      assigns
      |> assign(:effective, state)
      |> assign(:prefix, prefix)
      |> assign(:href, ~p"/editor/content/#{to_string(assigns.ct.type)}/#{record.id}")
      |> assign(:published?, record.state == :published)
      |> assign(:pending?, record.state == :published and WorkingCopy.pending?(record))
      |> assign(:draft?, record.state == :draft)
      |> assign(:current_title, view.title)
      |> assign(:error_count, error_count(assigns.errors))
      |> assign(
        :editing?,
        assigns.status != :stale and assigns.connected? and assigns.locked? != true
      )

    ~H"""
    <div
      id={"#{@dom_id}-card"}
      data-inline-card
      data-inline-status={@status}
      tabindex="-1"
      role="group"
      aria-labelledby={"#{@dom_id}-heading"}
      class="mt-2 space-y-3 rounded-md border border-base-content/10 bg-base-200/40 p-3"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-2">
        <p id={"#{@dom_id}-heading"} class="text-sm font-medium">
          {gettext("The %{type} record", type: @ct.label)}
        </p>
        <span class="text-xs text-base-content/70">{gettext("Saved on its own")}</span>
      </div>

      <p :if={@draft?} class="text-xs text-base-content/70">
        {gettext(
          "Draft: readers do not see this record, so the page leaves it out until it is published."
        )}
      </p>
      <p :if={@pending?} class="text-xs text-base-content/70">
        {gettext(
          "Showing the working copy. Readers see this once the record's changes are published."
        )}
      </p>
      <p :if={@published? and not @pending?} class="text-xs text-base-content/70">
        {gettext(
          "Published: your changes are saved to a working copy, and readers see them once you publish them."
        )}
      </p>

      <div
        :if={@status == :stale}
        id={"#{@dom_id}-stale"}
        role="alert"
        class="flex flex-wrap items-center gap-2 rounded-md border border-error/40 p-2 text-sm"
      >
        <span>
          {gettext("Someone changed this record since you opened it. Nothing was overwritten.")}
        </span>
        <button
          type="button"
          phx-click="reload"
          phx-target={@myself}
          data-inline-reload
          class="btn btn-sm"
        >
          {gettext("Reload this record")}
        </button>
      </div>

      <div
        :if={@status == :error and @error_count > 0}
        id={"#{@dom_id}-alert"}
        role="alert"
        class="rounded-md border border-error/40 p-2 text-sm"
      >
        {ngettext(
          "1 problem on this record. Nothing was saved.",
          "%{count} problems on this record. Nothing was saved.",
          @error_count
        )}
      </div>

      <ul :if={@errors[:base]} id={"#{@dom_id}-errors"} class="space-y-0.5">
        <li :for={message <- @errors[:base]} class="flex items-center gap-1 text-xs text-error">
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0" /> {message}
        </li>
      </ul>

      <div class="grid gap-x-3 gap-y-2 sm:grid-cols-2">
        <div class="sm:col-span-2">
          <%= if @title_editable? and @editing? do %>
            <label for={"#{@dom_id}-title"} class="mb-1 block text-xs font-medium">
              {gettext("Title")}
            </label>
            <input
              type="text"
              id={"#{@dom_id}-title"}
              name={"#{@prefix}[title]"}
              value={@values["title"]}
              autocomplete="off"
              phx-change="change"
              phx-target={@myself}
              aria-invalid={@errors["title"] != nil && "true"}
              aria-describedby={@errors["title"] != nil && "#{@dom_id}-title-errors"}
              class="field-input"
            />
            <ul
              :if={@errors["title"]}
              id={"#{@dom_id}-title-errors"}
              class="mt-1 space-y-0.5"
            >
              <li
                :for={message <- @errors["title"]}
                class="flex items-center gap-1 text-xs text-error"
              >
                <.icon name="hero-exclamation-circle" class="size-4 shrink-0" /> {message}
              </li>
            </ul>
          <% else %>
            <span class="mb-1 block text-xs font-medium">{gettext("Title")}</span>
            <p class="min-w-0 break-words text-sm text-base-content/80">
              {@current_title || gettext("Untitled")}
            </p>
          <% end %>
        </div>

        <%= for %{definition: definition, editable?: editable?} <- @shown,
                not @effective[definition.name].hidden? do %>
          <div class={definition.field_type == :text && "sm:col-span-2"}>
            <PlainField.field
              id={"#{@dom_id}-f-#{definition.name}"}
              definition={definition}
              name={"#{@prefix}[custom_fields][#{definition.name}]"}
              value={@values["custom_fields"][definition.name]}
              event="change"
              target={@myself}
              readonly={not editable? or not @editing?}
              required={@effective[definition.name].required?}
              errors={Map.get(@errors, definition.name, [])}
            />
          </div>
        <% end %>
      </div>

      <p :if={@more?} class="text-xs text-base-content/70">
        {gettext("Other fields, such as media and rich text, are edited in the full editor.")}
      </p>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <button
            :if={@editing?}
            type="button"
            id={"#{@dom_id}-save"}
            phx-click="save"
            phx-target={@myself}
            phx-disable-with={gettext("Saving…")}
            disabled={@status in [:clean, :saved, :saved_copy]}
            data-inline-save
            class="btn btn-primary btn-sm"
          >
            {gettext("Save %{type}", type: @ct.label)}
          </button>
          <button
            :if={@editing? and @status in [:dirty, :error]}
            type="button"
            phx-click="discard"
            phx-target={@myself}
            data-inline-discard
            class="btn btn-ghost btn-sm"
          >
            {gettext("Discard changes")}
          </button>
          <.link
            href={@href}
            target="_blank"
            rel="noopener"
            class="text-xs font-medium text-primary-ink hover:underline"
          >
            {gettext("Open in the full editor")}
          </.link>
        </div>
        <span
          id={"#{@dom_id}-chip"}
          role="status"
          data-inline-chip
          class={[
            "text-xs font-medium",
            @status == :dirty && "text-warning-ink",
            @status in [:saved, :saved_copy] && "text-success-ink",
            @status in [:error, :stale] && "text-error"
          ]}
        >
          {chip(@status)}
        </span>
      </div>
    </div>
    """
  end

  defp chip(:dirty), do: gettext("Unsaved changes")
  defp chip(:saved), do: gettext("Saved")
  defp chip(:saved_copy), do: gettext("Saved to the working copy")
  defp chip(:error), do: gettext("Error")
  defp chip(:stale), do: gettext("Changed by someone else")
  defp chip(_clean), do: ""

  defp error_count(errors), do: errors |> Map.values() |> List.flatten() |> length()
end
