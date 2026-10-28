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

  def custom_fields_panel(assigns) do
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
        <span
          :if={any_errors?(@form, @field_definitions)}
          class="inline-flex items-center gap-1 text-xs text-error"
        >
          <.icon name="hero-exclamation-circle" class="size-3.5" />
          {gettext("Needs attention")}
        </span>
      </header>
      <div class="space-y-4 p-4">
        <%!-- A shared field on a translation (#1327) is disabled, not just
              read-only: a disabled control is not submitted, and a custom
              field absent from the params keeps its stored value — the one
              the source variant's publish copied in. --%>
        <fieldset
          :for={definition <- @field_definitions}
          disabled={Localization.locked?(@localization, {:custom, definition.name})}
          class="contents"
        >
          <%!-- A reference searches its target type as the editor (R9), so
                it is a component with its own search state; the value
                still lives in this form. --%>
          <.live_component
            :if={definition.field_type == :reference}
            module={KilnCMSWeb.ContentEditor.ReferencePicker}
            id={"reference-picker-#{definition.name}"}
            definition={definition}
            name={"#{@form.name}[custom_fields][#{definition.name}]"}
            link_name={"#{@form.name}[_kiln_ref_link][#{definition.name}]"}
            value={custom_field_value(@form, definition.name)}
            errors={custom_field_errors(@form, definition.name)}
            locked={Localization.locked?(@localization, {:custom, definition.name})}
            actor={@actor}
            tenant={@tenant}
            source={%{id: @record && @record.id, type: to_string(@kind)}}
          />
          <.custom_field_input
            :if={definition.field_type != :reference}
            definition={definition}
            name={"#{@form.name}[custom_fields][#{definition.name}]"}
            value={input_value(@form, definition)}
            errors={custom_field_errors(@form, definition.name)}
            options={field_options(definition, assigns)}
          />
          <Localization.localization_note
            localization={@localization}
            field={{:custom, definition.name}}
            kind={@kind}
            inherited={Localization.inherited(@localization, {:custom, definition.name})}
          />
        </fieldset>
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
