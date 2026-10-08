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
    only: [custom_field_input: 1, custom_field_options: 3]

  import KilnCMSWeb.ContentEditor.Shared, only: [custom_field_errors: 2, custom_field_value: 2]

  alias KilnCMSWeb.ContentEditor.Localization

  attr :form, :any, required: true
  attr :field_definitions, :list, required: true
  attr :localization, :map, required: true
  attr :kind, :atom, required: true
  attr :media, :list, required: true
  attr :reference_options, :map, required: true
  attr :broken_references, :list, required: true

  def custom_fields_panel(assigns) do
    ~H"""
    <section
      :if={@field_definitions != []}
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
          <.custom_field_input
            definition={definition}
            name={"#{@form.name}[custom_fields][#{definition.name}]"}
            value={custom_field_value(@form, definition.name)}
            errors={custom_field_errors(@form, definition.name)}
            options={custom_field_options(definition, @media, @reference_options)}
          />
          <Localization.localization_note
            localization={@localization}
            field={{:custom, definition.name}}
            kind={@kind}
            inherited={Localization.inherited(@localization, {:custom, definition.name})}
          />
        </fieldset>
        <.broken_references references={@broken_references} definitions={@field_definitions} />
      </div>
    </section>
    """
  end

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
