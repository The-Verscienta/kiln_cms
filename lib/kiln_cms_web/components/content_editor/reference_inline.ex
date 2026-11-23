defmodule KilnCMSWeb.ContentEditor.ReferenceInline do
  @moduledoc """
  The expandable **record card** on a connected row of a reference field whose
  `edit_inline` option is on (#2283, `docs/plans/inline-reference-editing-plan.md`).

  This is the read-only first step: a disclosure on the row opens a card that
  shows the related record's title and its plain custom fields, as the actor may
  see them, and links to the record's own editor. Nothing here writes; the card
  that edits (its own form, its own save) is the next step of the plan.

  The rules the card keeps from the start, because the editing card inherits
  them:

    * **A card is offered only for a record the actor may write**
      (`KilnCMS.CMS.ContentTypes.can_write?/4`: its working copy when it is
      published, the row otherwise), in the parent's tenant. A record the actor
      cannot read is the row's *Unavailable* state and has no card; one they
      can read but not write has a row and no card.
    * **The server decides on every event.** `open/4` takes the row key the
      picker resolved from the field's current value, reads the record again as
      the actor and re-checks `can_write?`, so a forged `inline_toggle` for an
      unreadable, trashed, cross-tenant, read-only or unconnected record opens
      nothing.
    * **Read grants first.** A private field the actor's read grant hides
      (`KilnCMS.CMS.HiddenFields`) is not rendered at all.
    * **Narrow by construction.** Only the field types the "Add new" form
      renders (`plain_types/0`) are shown, and no field of another type, so no
      nested picker and no recursion. The rest is a link to the full editor.
    * **Lazy.** Nothing is read for a closed card; the picker reads the
      connected rows once to decide which get a disclosure, and one record per
      opened card.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.HiddenFields
  alias KilnCMS.CMS.WorkingCopy

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

  @doc """
  Opens the card of the record `id` of `ct` as `actor`: `{:ok, card}`, or
  `:error` when the record cannot be read now (gone, trashed, another tenant, a
  policy) or may not be written by the actor.
  """
  @spec open(map(), String.t(), term(), term()) :: {:ok, map()} | :error
  def open(ct, id, actor, tenant) do
    with {:ok, record} <- read(ct, id, actor, tenant),
         true <- can_write?(ct, record, actor, tenant) do
      {:ok, card(ct, record, actor, tenant)}
    else
      _refused -> :error
    end
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

  defp card(ct, record, actor, tenant) do
    view = WorkingCopy.view(record)
    hidden = HiddenFields.names(actor, record, tenant)
    values = Map.get(view, :custom_fields) || %{}

    fields =
      for definition <- definitions(ct, actor, tenant),
          shown?(definition, hidden) do
        %{label: definition.label, value: display(definition, Map.get(values, definition.name))}
      end

    %{
      title: view.title,
      state: record.state,
      pending?: WorkingCopy.pending?(record),
      type: to_string(ct.type),
      type_label: ct.label,
      href: ~p"/editor/content/#{to_string(ct.type)}/#{record.id}",
      fields: fields,
      more?: more?(ct, actor, tenant, hidden)
    }
  end

  defp definitions(ct, actor, tenant) do
    Enum.filter(all_definitions(ct, actor, tenant), &(&1.field_type in @plain_types))
  end

  defp all_definitions(%{source: :dynamic, definition: definition}, actor, tenant),
    do: CMS.field_definitions_for_definition!(definition.id, actor: actor, tenant: tenant)

  defp all_definitions(ct, actor, tenant),
    do: CMS.field_definitions_for!(ct.type, actor: actor, tenant: tenant)

  defp shown?(definition, hidden) do
    FieldDefinition.top_level?(definition) and definition.name not in hidden and
      is_nil(Map.get(definition, :default_source))
  end

  # Whether the record carries fields the card does not show, so the card says
  # so and points at the full editor.
  defp more?(ct, actor, tenant, hidden) do
    ct
    |> all_definitions(actor, tenant)
    |> Enum.any?(fn definition ->
      FieldDefinition.top_level?(definition) and definition.name not in hidden and
        (definition.field_type not in @plain_types or
           not is_nil(Map.get(definition, :default_source)))
    end)
  end

  defp display(_definition, nil), do: nil
  defp display(_definition, ""), do: nil
  defp display(%{field_type: :boolean}, true), do: gettext("Yes")
  defp display(%{field_type: :boolean}, false), do: gettext("No")

  defp display(%{field_type: :select} = definition, value) when is_binary(value),
    do: FieldDefinition.option_label(definition, value)

  defp display(_definition, value) when is_binary(value) or is_number(value), do: to_string(value)
  defp display(_definition, _value), do: nil

  # ── rendering ─────────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :open?, :boolean, default: false
  attr :target, :any, required: true

  @doc "The disclosure button of a row; the card renders under it with `card/1`."
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
          else: gettext("Show the record: %{title}", title: @item.title || gettext("Untitled"))
      }
      data-inline-toggle
      class="mt-1 inline-flex items-center gap-1 rounded text-xs font-medium text-primary-ink transition-colors hover:underline"
    >
      <.icon
        name={if @open?, do: "hero-chevron-down", else: "hero-chevron-right"}
        class="size-3.5"
      />
      <span aria-hidden="true">
        {if @open?, do: gettext("Hide the record"), else: gettext("Show the record")}
      </span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :card, :map, required: true

  @doc "The read-only card of an opened row."
  def card(assigns) do
    ~H"""
    <div
      id={"#{@id}-card"}
      data-inline-card
      class="mt-2 space-y-2 rounded-md border border-base-content/10 bg-base-200/40 p-3"
    >
      <p :if={@card.state == :draft} class="text-xs text-base-content/70">
        {gettext(
          "Draft: readers do not see this record, so the page leaves it out until it is published."
        )}
      </p>
      <p :if={@card.pending?} class="text-xs text-base-content/70">
        {gettext(
          "Showing the working copy. Readers see this once the record's changes are published."
        )}
      </p>
      <dl class="grid gap-x-4 gap-y-1.5 text-sm sm:grid-cols-[minmax(0,10rem)_1fr]">
        <dt class="text-xs font-medium text-base-content/70">{gettext("Title")}</dt>
        <dd class="min-w-0 break-words">{@card.title || gettext("Untitled")}</dd>
        <%= for field <- @card.fields do %>
          <dt class="text-xs font-medium text-base-content/70">{field.label}</dt>
          <dd class="min-w-0 break-words">
            {field.value || "—"}
          </dd>
        <% end %>
      </dl>
      <p class="text-xs text-base-content/70">
        <span :if={@card.more?}>
          {gettext("Other fields, such as media and rich text, are edited in the full editor.")}
        </span>
        <.link
          href={@card.href}
          target="_blank"
          rel="noopener"
          class="font-medium text-primary-ink hover:underline"
        >
          {gettext("Open in the full editor")}
        </.link>
      </p>
    </div>
    """
  end

  attr :id, :string, required: true

  @doc "What an opened card says when its record can no longer be opened."
  def refused(assigns) do
    ~H"""
    <p id={"#{@id}-refused"} role="status" class="mt-2 text-xs text-warning-ink">
      {gettext(
        "This record can no longer be opened here. It may have been deleted or its permissions changed."
      )}
    </p>
    """
  end
end
