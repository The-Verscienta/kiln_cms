defmodule KilnCMSWeb.FieldSelectionComponents do
  @moduledoc """
  The "Which records can be picked" step of a relationship on `/editor/fields`
  (#2285, part 3): states, "only records the editor created", a sort, and per
  ticked target type tags, a category and "field is" rows. Every input posts under
  `field_definition[sel]` and `KilnCMSWeb.FieldSelection.unpack/3` turns the
  posted rows into the `selection` map; the resource judges it, and its
  refusals show under the step. A sentence reads the setting back.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.CMS.ReferenceSelection
  alias KilnCMSWeb.FieldSelection

  @doc """
  What the step needs from the live view, built once per load: the org's tags
  and categories, and for each type the equality fields it offers.
  """
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :step, :integer, default: 6
  # The type names this field currently links to.
  attr :targets, :list, required: true
  # `%{tags: [{id, name}], categories: [{id, name}], types: %{name => label},
  #    fields: %{name => [%{name, label, field_type}]}}`
  attr :catalog, :map, required: true

  def selection_step(assigns) do
    selection = assigns.form[:selection].value
    view = FieldSelection.view(selection)

    lookup = %{
      tags: Map.new(assigns.catalog.tags, fn {id, name} -> {id, name} end),
      categories: Map.new(assigns.catalog.categories, fn {id, name} -> {id, name} end),
      types: assigns.catalog.types,
      fields:
        Map.new(assigns.catalog.fields, fn {type, defs} ->
          {type, Map.new(defs, &{&1.name, &1.label})}
        end)
    }

    assigns =
      assign(assigns,
        view: view,
        states: ReferenceSelection.states(),
        sentence: FieldSelection.sentence(selection, assigns.targets, lookup),
        errors:
          for({msg, opts} <- assigns.form[:selection].errors, do: translate_error({msg, opts}))
      )

    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-heading"} class="space-y-3 sm:col-span-2">
      <h3 id={"#{@id}-heading"} class="flex items-center gap-2 text-sm font-semibold">
        <span
          aria-hidden="true"
          class="inline-flex size-5 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-semibold text-primary-ink"
        >
          {@step}
        </span>
        {gettext("Which records can be picked")}
      </h3>
      <input type="hidden" name="field_definition[sel][_]" value="1" />
      <p class="text-xs text-base-content/70">
        {gettext(
          "Narrow what editors are offered and what a save may add. It never shows a record someone cannot already read, and it binds admins too. Leave everything empty to allow any record."
        )}
      </p>

      <fieldset id={"#{@id}-states"}>
        <legend class="mb-1 text-sm font-medium">{gettext("Only records that are")}</legend>
        <div class="flex flex-wrap gap-2">
          <label
            :for={state <- @states}
            for={"#{@id}-state-#{state}"}
            class={[
              "inline-flex cursor-pointer items-center gap-2 rounded-full border px-3 py-1 text-sm transition-colors",
              if(state in @view.states,
                do: "border-primary bg-primary/5",
                else: "border-base-content/15 hover:border-base-content/30"
              )
            ]}
          >
            <input
              type="checkbox"
              id={"#{@id}-state-#{state}"}
              name="field_definition[sel][states][]"
              value={state}
              checked={state in @view.states}
              class="size-3.5 rounded border border-base-content/30 accent-primary"
            />
            {state_text(state)}
          </label>
        </div>
        <p class="mt-1 text-xs text-base-content/70">
          {gettext("Tick none to offer records in any state the editor can read.")}
        </p>
      </fieldset>

      <label class="flex items-center gap-2 text-sm" for={"#{@id}-owner"}>
        <input
          type="checkbox"
          id={"#{@id}-owner"}
          name="field_definition[sel][owner]"
          value="self"
          checked={@view.owner?}
          class="size-3.5 rounded border border-base-content/30 accent-primary"
        />
        {gettext("Only records the editor created")}
      </label>

      <div>
        <label for={"#{@id}-sort"} class="mb-1 block text-sm font-medium">
          {gettext("Order a blank search")}
        </label>
        <select id={"#{@id}-sort"} name="field_definition[sel][sort]" class="field-select">
          <option value="recent" selected={@view.sort == "recent"}>
            {gettext("Newest first")}
          </option>
          <option value="title" selected={@view.sort == "title"}>{gettext("By title")}</option>
        </select>
      </div>

      <div
        :for={type <- @targets}
        id={"#{@id}-type-#{type}"}
        class="space-y-2 rounded-lg border border-base-content/10 p-3"
      >
        <% entry = Map.get(@view.by_type, type, %{tags: [], category: nil, fields: %{}}) %>
        <h4 class="text-sm font-medium">
          {gettext("Only %{type} records that match", type: Map.get(@catalog.types, type, type))}
        </h4>
        <p
          :if={
            length(@catalog.tags) >= @catalog.limit or length(@catalog.categories) >= @catalog.limit
          }
          class="text-xs text-base-content/70"
        >
          {gettext("Showing the first %{count} tags and categories by name.", count: @catalog.limit)}
        </p>

        <div>
          <label for={"#{@id}-#{type}-tags"} class="mb-1 block text-xs font-medium">
            {gettext("Tagged with any of")}
          </label>
          <select
            id={"#{@id}-#{type}-tags"}
            name={"field_definition[sel][by_type][#{type}][tags_any][]"}
            multiple
            size={min(max(length(@catalog.tags), 2), 6)}
            class="field-select"
          >
            <option
              :for={{id, name} <- missing(entry.tags, @catalog.tags)}
              value={id}
              selected
            >
              {name}
            </option>
            <option :for={{id, name} <- @catalog.tags} value={id} selected={id in entry.tags}>
              {name}
            </option>
          </select>
          <p :if={@catalog.tags == []} class="mt-1 text-xs text-base-content/70">
            {gettext("This site has no tags yet.")}
          </p>
        </div>

        <div>
          <label for={"#{@id}-#{type}-category"} class="mb-1 block text-xs font-medium">
            {gettext("In category")}
          </label>
          <select
            id={"#{@id}-#{type}-category"}
            name={"field_definition[sel][by_type][#{type}][category]"}
            class="field-select"
          >
            <option value="">{gettext("Any category")}</option>
            <option
              :for={{id, name} <- missing(List.wrap(entry.category), @catalog.categories)}
              value={id}
              selected
            >
              {name}
            </option>
            <option
              :for={{id, name} <- @catalog.categories}
              value={id}
              selected={id == entry.category}
            >
              {name}
            </option>
          </select>
        </div>

        <div
          :for={field <- Map.get(@catalog.fields, type, [])}
          class="grid gap-1 sm:grid-cols-[1fr_auto_2fr] sm:items-end"
        >
          <% {op, value} = Map.get(entry.fields, field.name, {"eq", ""}) %>
          <label
            for={"#{@id}-#{type}-field-#{field.name}-value"}
            class="text-xs font-medium sm:self-center"
          >
            {field.label}
          </label>
          <select
            id={"#{@id}-#{type}-field-#{field.name}-op"}
            name={"field_definition[sel][by_type][#{type}][fields][#{field.name}][op]"}
            aria-label={gettext("How %{field} is compared", field: field.label)}
            class="field-select"
          >
            <option value="eq" selected={op == "eq"}>{gettext("equals")}</option>
            <option value="in" selected={op == "in"}>{gettext("is one of")}</option>
            <option value="not_eq" selected={op == "not_eq"}>{gettext("is not")}</option>
          </select>
          <input
            type="text"
            id={"#{@id}-#{type}-field-#{field.name}-value"}
            name={"field_definition[sel][by_type][#{type}][fields][#{field.name}][value]"}
            value={value}
            autocomplete="off"
            class="field-input"
          />
        </div>
        <p :if={Map.get(@catalog.fields, type, []) != []} class="text-xs text-base-content/70">
          {gettext(
            "Leave a value empty to not filter on that field. For “is one of”, separate the values with commas."
          )}
        </p>
      </div>

      <p :for={error <- @errors} class="flex items-center gap-1.5 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-4" />{error}
      </p>

      <p
        :if={@sentence}
        id={"#{@id}-sentence"}
        aria-live="polite"
        class="text-sm text-base-content/80"
      >
        {gettext("Editors are offered: %{sentence}", sentence: @sentence)}
      </p>
    </section>
    """
  end

  # Ids a stored condition names that the site no longer lists, kept visible
  # (and selected) so saving does not silently drop them: "(not found)".
  defp missing(ids, listed) do
    known = MapSet.new(listed, &elem(&1, 0))

    for id <- ids,
        not MapSet.member?(known, id),
        do: {id, gettext("(not found)") <> " " <> String.slice(id, 0, 8)}
  end

  defp state_text("draft"), do: gettext("Draft")
  defp state_text("in_review"), do: gettext("In review")
  defp state_text("published"), do: gettext("Published")
  defp state_text("archived"), do: gettext("Archived")
end
