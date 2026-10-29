defmodule KilnCMSWeb.ContentEditor.CustomFieldsPanel do
  @moduledoc """
  The content editor's Custom fields panel: one input per admin-defined field
  (`KilnCMS.CMS.FieldDefinition`) for the record's type.

  It sits in the main column under the blocks, not in the inspector rail. The
  rail opens on Preview, so fields kept behind its Settings tab were fields a
  writer had to know to go looking for — and a type's own fields (the recipe's
  chef, the event's venue) are content, written alongside the body, not a
  setting. Same placement as WordPress's meta boxes under the post body.

  Like the rail, nothing here introduces a `<form>`: the panel renders inside
  the page's own editor form, and its inputs are named into that form's
  `custom_fields` map, so change and save events carry them as before.
  """

  use KilnCMSWeb, :html

  import KilnCMSWeb.ContentEditor.InspectorComponents,
    only: [custom_field_input: 1, custom_field_options: 2]

  import KilnCMSWeb.ContentEditor.Shared, only: [custom_field_errors: 2, custom_field_value: 2]

  alias KilnCMSWeb.ContentEditor.GroupRows
  alias KilnCMSWeb.ContentEditor.Localization

  attr :form, :any, required: true
  attr :field_definitions, :list, required: true
  attr :localization, :map, required: true
  attr :kind, :atom, required: true
  attr :media, :list, required: true
  # `{label, id}` for a `:user` field's picker (#2044).
  attr :people, :list, default: []
  # Terms in use per open-vocabulary multiple select (`KilnCMS.CMS.SelectTerms`).
  attr :select_terms, :map, default: %{}
  attr :actor, :any, required: true
  attr :tenant, :any, required: true
  attr :broken_references, :list, required: true
  attr :record, :any, default: nil
  attr :reverse_fields, :list, default: []

  # What every field row needs from the panel.
  @row_assigns [
    :form,
    :localization,
    :kind,
    :media,
    :people,
    :select_terms,
    :actor,
    :tenant,
    :record
  ]

  def custom_fields_panel(assigns) do
    assigns = assign(assigns, :sections, sections(assigns.field_definitions))

    ~H"""
    <section
      :if={@field_definitions != [] or show_reverse?(@record, @reverse_fields)}
      id="custom-fields"
      aria-labelledby="custom-fields-heading"
      class="rounded-lg border border-base-content/10 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-2 border-b border-base-content/10 px-4 py-3">
        <h2 id="custom-fields-heading" class="flex items-center gap-2 text-lg font-medium">
          <.icon name="hero-rectangle-stack" class="size-5 text-base-content/50" />
          {gettext("Custom fields")}
        </h2>
        <div class="flex items-center gap-3">
          <span
            :if={any_errors?(@form, @field_definitions)}
            class="inline-flex items-center gap-1 text-xs text-error"
          >
            <.icon name="hero-exclamation-circle" class="size-3.5" />
            {gettext("Needs attention")}
          </span>
          <div
            :if={Enum.any?(@field_definitions, & &1.section)}
            class="flex items-center gap-1 text-xs"
          >
            <button
              type="button"
              id="cf-sections-expand"
              phx-click={expand_all()}
              class="rounded px-1.5 py-0.5 text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
            >
              {gettext("Expand all")}
            </button>
            <span class="text-base-content/30" aria-hidden="true">·</span>
            <button
              type="button"
              id="cf-sections-collapse"
              phx-click={collapse_all()}
              class="rounded px-1.5 py-0.5 text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
            >
              {gettext("Collapse all")}
            </button>
          </div>
        </div>
      </header>
      <div class="space-y-4 p-4">
        <%!-- Fields an admin filed under a heading (`section`) group under
              it, collapsible, at the place of the section's first field;
              the rest render bare. A collapsed section only hides its
              inputs, so they still submit like any other. --%>
        <%= for {section, definitions, index} <- @sections do %>
          <.field_row
            :for={definition <- definitions}
            :if={is_nil(section)}
            definition={definition}
            {row_assigns(assigns)}
          />
          <.field_section
            :if={section}
            id={"cf-section-#{index}"}
            title={section}
            definitions={definitions}
            open={open_section?(@form, definitions, @sections)}
            filled={Enum.count(definitions, &filled?(input_value(@form, &1)))}
            errors={Enum.any?(definitions, &(custom_field_errors(@form, &1.name) != []))}
          >
            <.field_row
              :for={definition <- definitions}
              definition={definition}
              {row_assigns(assigns)}
            />
          </.field_section>
        <% end %>
        <%!-- The other side of references pointing here (R4): the records
              that connect to this one, read-only — each is changed from
              its own editor. --%>
        <.live_component
          :for={reverse <- @reverse_fields}
          :if={show_reverse?(@record, @reverse_fields)}
          module={KilnCMSWeb.ContentEditor.ReverseField}
          id={"reverse-field-#{reverse.source_type}-#{reverse.field}"}
          reverse={reverse}
          record={@record}
          actor={@actor}
          tenant={@tenant}
        />
        <.broken_references references={@broken_references} definitions={@field_definitions} />
      </div>
    </section>
    """
  end

  defp row_assigns(assigns), do: Map.take(assigns, @row_assigns)

  attr :definition, :map, required: true
  attr :form, :any, required: true
  attr :localization, :map, required: true
  attr :kind, :atom, required: true
  attr :media, :list, required: true
  attr :people, :list, required: true
  attr :select_terms, :map, required: true
  attr :actor, :any, required: true
  attr :tenant, :any, required: true
  attr :record, :any, required: true

  # One field's input, its localization note, and — a shared field on a
  # translation (#1327) — the disabled fieldset that keeps it out of the
  # submit: a disabled control is not submitted, and a custom field absent
  # from the params keeps its stored value, the one the source variant's
  # publish copied in.
  defp field_row(assigns) do
    ~H"""
    <fieldset
      disabled={Localization.locked?(@localization, {:custom, @definition.name})}
      class="contents"
    >
      <%!-- A reference searches its target type as the editor (R9), so it
            is a component with its own search state; the value still lives
            in this form. --%>
      <.live_component
        :if={@definition.field_type == :reference}
        module={KilnCMSWeb.ContentEditor.ReferencePicker}
        id={"reference-picker-#{@definition.name}"}
        definition={@definition}
        name={"#{@form.name}[custom_fields][#{@definition.name}]"}
        link_name={"#{@form.name}[_kiln_ref_link][#{@definition.name}]"}
        value={custom_field_value(@form, @definition.name)}
        errors={custom_field_errors(@form, @definition.name)}
        locked={Localization.locked?(@localization, {:custom, @definition.name})}
        actor={@actor}
        tenant={@tenant}
        source={%{id: @record && @record.id, type: to_string(@kind)}}
      />
      <.custom_field_input
        :if={@definition.field_type != :reference}
        definition={@definition}
        name={"#{@form.name}[custom_fields][#{@definition.name}]"}
        value={input_value(@form, @definition)}
        errors={custom_field_errors(@form, @definition.name)}
        options={field_options(@definition, assigns)}
        placeholder={Localization.placeholder(@localization, {:custom, @definition.name})}
      />
      <Localization.localization_note
        localization={@localization}
        field={{:custom, @definition.name}}
        kind={@kind}
        inherited={Localization.inherited(@localization, {:custom, @definition.name})}
      />
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :definitions, :list, required: true
  attr :open, :boolean, required: true
  attr :filled, :integer, required: true
  attr :errors, :boolean, required: true
  slot :inner_block, required: true

  # A collapsible section of fields. Toggled with `JS` commands rather than
  # an assign: they need no round trip, and LiveView keeps what they set
  # across the patches every keystroke brings, so a section stays as the
  # writer left it. A section holding an error is always rendered open.
  defp field_section(assigns) do
    assigns = assign(assigns, :open, assigns.open or assigns.errors)

    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-heading"}
      class="rounded-lg border border-base-content/10 bg-base-200/20 transition-colors"
    >
      <h3 id={"#{@id}-heading"} class="m-0">
        <button
          type="button"
          id={"#{@id}-toggle"}
          data-cf-section-toggle
          aria-expanded={to_string(@open)}
          aria-controls={"#{@id}-body"}
          phx-click={toggle_section(@id)}
          class="group flex w-full items-center gap-2 rounded-lg px-3 py-2.5 text-left text-sm font-medium transition-colors hover:bg-base-200/60"
        >
          <.icon
            name="hero-chevron-right"
            class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 group-aria-expanded:rotate-90"
          />
          <span class="min-w-0 flex-1 truncate">{@title}</span>
          <.icon :if={@errors} name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          <span class="shrink-0 text-xs font-normal tabular-nums text-base-content/50">
            {gettext("%{filled} of %{count} filled",
              filled: @filled,
              count: length(@definitions)
            )}
          </span>
        </button>
      </h3>
      <div
        id={"#{@id}-body"}
        data-cf-section-body
        class={["space-y-4 border-t border-base-content/10 p-3", !@open && "hidden"]}
      >
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp toggle_section(id) do
    JS.toggle_class("hidden", to: "##{id}-body")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{id}-toggle")
  end

  defp expand_all do
    JS.remove_class("hidden", to: "[data-cf-section-body]")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "[data-cf-section-toggle]")
  end

  defp collapse_all do
    JS.add_class("hidden", to: "[data-cf-section-body]")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "[data-cf-section-toggle]")
  end

  # The definitions in `position` order, grouped by `section` at the place of
  # each section's first field: `[{section | nil, [definition], index}]`.
  # Unsectioned fields between two sections stay where they are, as their
  # own unheaded run, rather than all being swept to the top.
  @doc false
  def sections(definitions) do
    definitions
    |> Enum.chunk_by(& &1.section)
    |> Enum.reduce([], &file_run/2)
    |> Enum.with_index(fn {section, defs}, index -> {section, defs, index} end)
  end

  # A run of fields sharing a section joins that section where it first
  # appeared; an unsectioned run, or a section's first run, is a new group.
  defp file_run([%{section: nil} | _] = run, acc), do: acc ++ [{nil, run}]

  defp file_run([%{section: key} | _] = run, acc) do
    case Enum.find_index(acc, &match?({^key, _defs}, &1)) do
      nil -> acc ++ [{key, run}]
      at -> List.update_at(acc, at, fn {section, defs} -> {section, defs ++ run} end)
    end
  end

  # Whether a section starts open: one whose fields already hold a stored
  # value does — read from the record, not the form, so typing into or
  # emptying a field never folds its section away mid-edit — and, when no
  # section holds anything yet (a new record), the first one does, so the
  # panel never opens as a wall of closed headings. Every other section
  # starts closed, which is the point: a type with a hundred fields opens on
  # the few a writer is filling in.
  defp open_section?(form, definitions, sections) do
    stored = stored_fields(form)
    holds? = fn defs -> Enum.any?(defs, &filled?(Map.get(stored, &1.name))) end

    holds?.(definitions) or
      (first_headed(sections) == definitions and
         not Enum.any?(sections, fn {section, defs, _i} -> section && holds?.(defs) end))
  end

  defp first_headed(sections) do
    Enum.find_value(sections, fn {section, defs, _index} -> section && defs end)
  end

  defp stored_fields(%{data: %{custom_fields: %{} = stored}}), do: stored
  defp stored_fields(_form), do: %{}

  defp filled?(value) when value in [nil, "", [], %{}], do: false
  defp filled?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled?(value) when is_list(value), do: Enum.any?(value, &filled?/1)

  defp filled?(%{} = value) when not is_struct(value),
    do: Enum.any?(Map.values(value), &filled?/1)

  defp filled?(_value), do: true

  # A group shows the rows as posted while the form holds them: the cleaned
  # value `custom_field_value/2` prefers has already dropped a blank row, so
  # "Add row" would add nothing anyone could see.
  defp input_value(form, %{field_type: :group, name: name}), do: GroupRows.posted(form, name)

  # A list of phrases likewise: an item emptied in place keeps its row while
  # the form holds it, and the cleaned value has dropped it.
  defp input_value(form, %{field_type: :string, multiple: true, name: name}),
    do: GroupRows.posted(form, name)

  defp input_value(form, definition), do: custom_field_value(form, definition.name)

  # What a field's input offers: the site's people for a `:user` field (#2044),
  # the field's options then the terms in use for a multiple select, the
  # library for a media field.
  defp field_options(%{field_type: :user}, assigns), do: assigns.people

  defp field_options(%{field_type: :select, multiple: true} = definition, assigns),
    do: Enum.uniq(definition.options ++ Map.get(assigns.select_terms, definition.name, []))

  defp field_options(definition, assigns), do: custom_field_options(definition, assigns.media)

  # An unsaved draft has no id yet, so nothing can connect to it.
  defp show_reverse?(record, reverse_fields),
    do: reverse_fields != [] and is_map(record) and not is_nil(Map.get(record, :id))

  defp any_errors?(form, definitions),
    do: Enum.any?(definitions, &(custom_field_errors(form, &1.name) != []))

  attr :references, :list, required: true
  attr :definitions, :list, required: true

  # A reference whose target was moved to the trash or deleted (#1594). The
  # stored snapshot still names it, so the field looks filled in; this is the
  # only place that says the link leads nowhere. Clearing or re-pointing the
  # field and saving removes the edge.
  defp broken_references(assigns) do
    ~H"""
    <div
      :if={@references != []}
      id="broken-references"
      role="status"
      class="rounded border border-warning/40 bg-warning/10 p-2 text-xs text-warning-ink"
    >
      <p class="flex items-center gap-1 font-medium">
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("Broken references")}
      </p>
      <ul class="mt-1 list-disc space-y-0.5 pl-5">
        <li :for={ref <- @references} id={"broken-reference-#{ref.field}"}>
          {gettext("%{field} points at a record that was deleted or moved to the trash.",
            field: field_label(@definitions, ref.field)
          )}
        </li>
      </ul>
    </div>
    """
  end

  defp field_label(definitions, name) do
    case Enum.find(definitions, &(&1.name == name)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _other -> name
    end
  end
end
