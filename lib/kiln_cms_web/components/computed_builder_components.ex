defmodule KilnCMSWeb.ComputedBuilderComponents do
  @moduledoc """
  The formula builder for a computed custom field on `/editor/fields` — how an
  admin who doesn't write formulas defines one, and how one who does gets
  help writing it.

  Two views over the one `compute` formula (state in `KilnCMSWeb.ComputedBuilder`):

    * **Recipe** — the macro builder. A grid of common computations
      (`KilnCMS.CMS.Computed.Recipes`); picking one shows its slots as plain
      form controls — a value picker over the document and this type's other
      fields, a text box, a number, a comparison — and the formula it writes.
    * **Formula** — the code builder. The template itself, with a palette that
      inserts a value or a function at the caret (inside `{{ … }}` when the
      caret is already in an expression, wrapped in one when it isn't), every
      function listed with its signature and what it does.

  Both share a **live preview**: the formula evaluated against one of the
  type's most recently edited documents (or sample text when the type has none
  yet), refreshed on every keystroke, through exactly the evaluator the save
  and publish paths use.

  Every control here is an ordinary input of the definition form, under
  `field_definition[builder][…]`, so the page's own `phx-change` drives the
  builder and no component state exists outside the LiveView.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [icon: 1, input: 1, translate_error: 1]

  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.Computed.Recipes
  alias Phoenix.LiveView.ColocatedHook

  attr :form, :any, required: true, doc: "the field definition form"
  attr :builder, :map, required: true, doc: "a `KilnCMSWeb.ComputedBuilder` state"
  attr :ctx, :map, required: true, doc: "values, samples and preview (`FieldDefinitionLive`)"
  attr :id, :string, required: true, doc: "a DOM id prefix unique to this form"
  attr :recipes, :list, required: true, doc: "`Recipes.all/0`, built once per page"
  attr :categories, :list, required: true, doc: "`categories/1`, built once per page"

  def compute_builder(assigns) do
    ~H"""
    <section
      id={"#{@id}-builder"}
      class="space-y-4 rounded-lg border border-base-content/10 bg-base-200/40 p-4 sm:col-span-2"
      aria-labelledby={"#{@id}-builder-heading"}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 id={"#{@id}-builder-heading"} class="text-sm font-medium">{gettext("Formula")}</h3>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Worked out from the document on every save and every publish. Editors see the result but can't type into it."
            )}
          </p>
        </div>
        <div class="tabs" role="radiogroup" aria-label={gettext("How to build the formula")}>
          <.mode_tab id={@id} mode="recipe" current={@builder.mode} icon="hero-squares-2x2">
            {gettext("Recipe")}
          </.mode_tab>
          <.mode_tab id={@id} mode="formula" current={@builder.mode} icon="hero-code-bracket">
            {gettext("Formula")}
          </.mode_tab>
        </div>
      </div>

      <%!-- Narrow attrs, not the whole `@ctx`/`@builder`: the preview changes on
           every keystroke, and LiveView tracks `@ctx.values` apart from
           `@ctx.preview`, so the palettes and the recipe grid are only re-sent
           when what they show changes. --%>
      <.recipe_view
        :if={@builder.mode == "recipe"}
        form={@form}
        builder={@builder}
        recipes={@recipes}
        recipe_id={@builder.recipe}
        values={@ctx.values}
        id={@id}
      />
      <.formula_view
        :if={@builder.mode == "formula"}
        form={@form}
        values={@ctx.values}
        categories={@categories}
        id={@id}
      />
      <.preview
        samples={@ctx.samples}
        sample={@ctx.sample}
        result={@ctx.preview}
        today={@ctx.today}
        time_dependent={@ctx.time_dependent?}
        id={@id}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :mode, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp mode_tab(assigns) do
    ~H"""
    <label class={[
      "tab has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-primary",
      @mode == @current && "tab-active"
    ]}>
      <input
        type="radio"
        id={"#{@id}-mode-#{@mode}"}
        name="field_definition[builder][mode]"
        value={@mode}
        checked={@mode == @current}
        class="sr-only"
      />
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </label>
    """
  end

  # --- recipe view (the macro builder) ---------------------------------------

  attr :form, :any, required: true
  attr :builder, :map, required: true
  attr :recipes, :list, required: true
  attr :recipe_id, :string, default: nil
  attr :values, :list, required: true
  attr :id, :string, required: true

  defp recipe_view(assigns) do
    assigns = assign(assigns, :recipe, Enum.find(assigns.recipes, &(&1.id == assigns.recipe_id)))

    ~H"""
    <div class="space-y-4">
      <.recipe_grid recipes={@recipes} recipe_id={@recipe_id} id={@id} />

      <p
        :if={@builder.unmatched?}
        class="flex items-start gap-2 rounded-md bg-warning/10 px-3 py-2 text-xs text-warning-ink"
      >
        <.icon name="hero-information-circle" class="size-4 shrink-0" />
        {gettext(
          "This formula doesn't match a recipe, so it's kept as written. Picking a recipe replaces it."
        )}
      </p>

      <div :if={@recipe} class="grid gap-3 rounded-md bg-base-100 p-3 sm:grid-cols-2">
        <.slot_input
          :for={slot <- visible_slots(@recipe, @builder.slots)}
          slot={slot}
          value={Map.get(@builder.slots, slot.key, slot.default)}
          values={@values}
          id={@id}
        />
      </div>

      <p
        :if={@builder.pending}
        class={[
          "flex items-center gap-2 text-sm",
          if(submitted?(@form), do: "text-error", else: "text-base-content/70")
        ]}
      >
        <.icon
          name={if submitted?(@form), do: "hero-exclamation-circle", else: "hero-pencil-square"}
          class="size-5"
        />
        {@builder.pending}
      </p>

      <p :if={@builder.error} class="flex items-center gap-2 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        {@builder.error}
      </p>
      <p
        :for={error <- compute_errors(@form, @builder)}
        class="flex items-center gap-2 text-sm text-error"
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        {error}
      </p>

      <input
        type="hidden"
        id={"#{@id}-compute"}
        name={@form[:compute].name}
        value={@form[:compute].value}
      />
      <div
        :if={present?(@form[:compute].value)}
        class="flex flex-wrap items-baseline gap-x-2 gap-y-1 text-xs text-base-content/60"
      >
        <span>{gettext("Formula it writes:")}</span>
        <code class="break-all rounded bg-base-100 px-1.5 py-0.5 font-mono text-base-content/80">
          {@form[:compute].value}
        </code>
        <span>{gettext("Switch to Formula to change it by hand.")}</span>
      </div>
    </div>
    """
  end

  attr :recipes, :list, required: true
  attr :recipe_id, :string, default: nil
  attr :id, :string, required: true

  defp recipe_grid(assigns) do
    ~H"""
    <fieldset>
      <legend class="mb-2 text-xs font-medium text-base-content/70">
        {gettext("Pick what this field should work out")}
      </legend>
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <label
          :for={recipe <- @recipes}
          class={[
            "flex cursor-pointer flex-col gap-0.5 rounded-md border p-3 transition-colors",
            "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-primary",
            if(recipe.id == @recipe_id,
              do: "border-primary bg-primary/5 shadow-sm",
              else: "border-base-content/15 bg-base-100 hover:border-primary/50"
            )
          ]}
        >
          <input
            type="radio"
            id={"#{@id}-recipe-#{recipe.id}"}
            name="field_definition[builder][recipe]"
            value={recipe.id}
            checked={recipe.id == @recipe_id}
            class="sr-only"
          />
          <span class="flex items-center gap-1.5 text-sm font-medium">
            <.icon
              :if={recipe.id == @recipe_id}
              name="hero-check-circle-mini"
              class="size-4 text-primary-ink"
            />
            {recipe.label}
          </span>
          <span class="text-xs text-base-content/60">{recipe.summary}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  attr :slot, :map, required: true
  attr :value, :string, required: true
  attr :values, :list, required: true
  attr :id, :string, required: true

  defp slot_input(%{slot: %{kind: :value}} = assigns) do
    ~H"""
    <.input
      type="select"
      id={"#{@id}-slot-#{@slot.key}"}
      name={"field_definition[builder][slots][#{@slot.key}]"}
      label={@slot.label}
      value={@value}
      options={with_current(@values, @value)}
      prompt={if @slot.required?, do: gettext("— Pick a value —"), else: gettext("— None —")}
    />
    """
  end

  defp slot_input(%{slot: %{kind: :operator}} = assigns) do
    ~H"""
    <.input
      type="select"
      id={"#{@id}-slot-#{@slot.key}"}
      name={"field_definition[builder][slots][#{@slot.key}]"}
      label={@slot.label}
      value={@value}
      options={Enum.map(Recipes.operators(), fn {op, label} -> {label, op} end)}
    />
    """
  end

  defp slot_input(%{slot: %{kind: :number}} = assigns) do
    ~H"""
    <.input
      type="number"
      id={"#{@id}-slot-#{@slot.key}"}
      name={"field_definition[builder][slots][#{@slot.key}]"}
      label={@slot.label}
      value={@value}
      min="0"
      step="1"
    />
    """
  end

  defp slot_input(assigns) do
    ~H"""
    <.input
      type="text"
      id={"#{@id}-slot-#{@slot.key}"}
      name={"field_definition[builder][slots][#{@slot.key}]"}
      label={@slot.label}
      value={@value}
      phx-debounce="300"
    />
    """
  end

  # "Compared with" means nothing to "is empty".
  defp visible_slots(%{id: "conditional", slots: slots}, %{"operator" => "is_empty"}),
    do: Enum.reject(slots, &(&1.key == "compare"))

  defp visible_slots(recipe, _slots), do: recipe.slots

  # A stored reference the picker no longer offers — a field deleted or renamed
  # since — stays selectable under its own name. A select can't show a value
  # it has no option for, and silently falling to the prompt would rewrite the
  # formula on the next unrelated change.
  defp with_current(groups, value) when is_binary(value) and value != "" do
    offered? =
      Enum.any?(groups, fn {_group, options} -> Enum.any?(options, &(elem(&1, 1) == value)) end)

    if offered?,
      do: groups,
      else: groups ++ [{gettext("No longer available"), [{value, value}]}]
  end

  defp with_current(groups, _value), do: groups

  # The resource's own errors on `compute` ("needs a formula"), once they mean
  # something: after a recipe is picked or a submit was tried, and never on top
  # of the builder's own, more specific message or blank-to-fill prompt.
  defp compute_errors(form, builder) do
    if builder.error == nil and builder.pending == nil and
         (builder.recipe != nil or submitted?(form)),
       do: Enum.map(form[:compute].errors, &translate_error/1),
       else: []
  end

  defp submitted?(%{source: %AshPhoenix.Form{submitted_once?: true}}), do: true
  defp submitted?(_form), do: false

  # --- formula view (the code builder) ---------------------------------------

  attr :form, :any, required: true
  attr :values, :list, required: true
  attr :categories, :list, required: true
  attr :id, :string, required: true

  defp formula_view(assigns) do
    ~H"""
    <%!-- A literal `phx-hook`: the colocated `.FormulaEditor` shorthand is only
         expanded when written as a plain string. --%>
    <div id={"#{@id}-formula"} phx-hook=".FormulaEditor" class="space-y-4">
      <.input
        type="textarea"
        field={@form[:compute]}
        id={"#{@id}-compute"}
        label={gettext("Formula")}
        placeholder={placeholder()}
        rows="3"
        spellcheck="false"
        autocomplete="off"
        phx-debounce="250"
        class="min-h-20 w-full rounded-lg border border-base-content/15 bg-base-100 px-3 py-2 font-mono text-sm text-base-content transition placeholder:text-base-content/60 focus:border-primary/50 focus:outline-none focus:ring-2 focus:ring-primary/20"
        hint={
          gettext(
            "Text outside {{ }} is shown as written. Inside, use a value or a function, like {{ upcase(title) }}. Text inside a function goes in quotes."
          )
        }
      />

      <div class="space-y-1.5">
        <p id={"#{@id}-values-label"} class="text-xs font-medium text-base-content/70">
          {gettext("Insert a value")}
        </p>
        <div class="flex flex-wrap gap-1.5" role="group" aria-labelledby={"#{@id}-values-label"}>
          <%= for {_group, options} <- @values, {label, ref} <- options do %>
            <button
              type="button"
              data-insert-ref={ref}
              title={ref}
              aria-label={gettext("Insert %{value}", value: label)}
              class="rounded-full border border-base-content/15 bg-base-100 px-2.5 py-0.5 text-xs text-base-content/80 transition-colors hover:border-primary hover:text-primary-ink"
            >
              {label}
            </button>
          <% end %>
        </div>
      </div>

      <div class="space-y-1.5">
        <p class="text-xs font-medium text-base-content/70">{gettext("Insert a function")}</p>
        <div class="grid items-start gap-2 lg:grid-cols-2">
          <details
            :for={{category, label, functions} <- @categories}
            class="group rounded-md border border-base-content/10 bg-base-100"
            open={category == :text}
          >
            <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 text-xs font-medium">
              <span>{label}</span>
              <.icon
                name="hero-chevron-down-mini"
                class="size-4 text-base-content/50 transition-transform group-open:rotate-180"
              />
            </summary>
            <ul class="divide-y divide-base-content/5 border-t border-base-content/10">
              <li :for={function <- functions}>
                <button
                  type="button"
                  data-insert-fn={function.name}
                  class="flex w-full flex-col gap-0.5 px-3 py-1.5 text-left transition-colors hover:bg-base-200/70 focus-visible:bg-base-200/70 focus-visible:outline-none"
                >
                  <code class="font-mono text-xs text-base-content">{function.signature}</code>
                  <span class="text-xs text-base-content/60">{function.summary}</span>
                </button>
              </li>
            </ul>
          </details>
        </div>
      </div>
    </div>
    <script :type={ColocatedHook} name=".FormulaEditor">
      // A value or function button inserts at the formula's caret, then fires
      // `input` so the form's phx-change (and the live preview) sees it. Inside
      // an open {{ … }} it inserts the bare name; outside one it wraps it, so a
      // click never leaves a reference sitting in literal text. A function
      // leaves the caret between its parentheses, ready for its arguments.
      export default {
        mounted() {
          this.el.addEventListener("click", (e) => {
            const button = e.target.closest("[data-insert-ref], [data-insert-fn]")
            const field = this.el.querySelector("textarea")
            if (!button || !field) return
            const start = field.selectionStart ?? field.value.length
            const end = field.selectionEnd ?? field.value.length
            const before = field.value.slice(0, start)
            const inside = before.lastIndexOf("{{") > before.lastIndexOf("}}")
            const fn = button.dataset.insertFn
            const bare = fn ? `${fn}()` : button.dataset.insertRef
            const text = inside ? bare : `{{ ${bare} }}`
            const caret = fn ? text.indexOf("(") + 1 : text.length
            field.value = field.value.slice(0, start) + text + field.value.slice(end)
            field.focus()
            field.setSelectionRange(start + caret, start + caret)
            field.dispatchEvent(new Event("input", {bubbles: true}))
          })
        },
      }
    </script>
    """
  end

  # A literal, so the `{{ … }}` never reaches HEEx as markup.
  defp placeholder, do: "{{ reading_time(body) }} min read"

  @doc """
  The function palette's groups, `{category, label, functions}`, from
  `Computed.catalog/0`. Built once per page (it calls gettext for every
  function) and passed back in as `categories`.
  """
  def categories do
    labels = [
      text: gettext("Text"),
      numbers: gettext("Numbers"),
      logic: gettext("Conditions"),
      dates: gettext("Dates")
    ]

    by_category = Enum.group_by(Computed.catalog(), & &1.category)
    for {category, label} <- labels, do: {category, label, Map.get(by_category, category, [])}
  end

  # --- preview ---------------------------------------------------------------

  attr :samples, :list, required: true
  attr :sample, :string, default: nil
  attr :result, :any, required: true
  attr :today, Date, required: true
  attr :time_dependent, :boolean, default: false
  attr :id, :string, required: true

  defp preview(assigns) do
    ~H"""
    <div class="space-y-2 rounded-md border border-base-content/10 bg-base-100 p-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p class="flex items-center gap-1.5 text-xs font-medium text-base-content/70">
          <.icon name="hero-eye" class="size-4" />
          {gettext("Preview")}
        </p>
        <div
          :if={@samples != []}
          class="flex min-w-0 items-center gap-2 text-xs text-base-content/70 [&>div]:mb-0"
        >
          <label for={"#{@id}-sample"}>{gettext("Try it on")}</label>
          <.input
            type="select"
            id={"#{@id}-sample"}
            name="field_definition[builder][sample]"
            value={@sample}
            options={@samples}
            class="min-w-0 max-w-56 cursor-pointer truncate rounded-md border border-base-content/15 bg-base-100 py-1 pl-2 pr-7 text-xs text-base-content transition focus:border-primary/50 focus:outline-none focus:ring-2 focus:ring-primary/20"
          />
        </div>
      </div>
      <p :if={@samples == []} class="text-xs text-base-content/60">
        {gettext("No content of this type yet, so the preview uses sample text.")}
      </p>
      <div id={"#{@id}-preview"} aria-live="polite" class="text-sm">
        <.preview_result result={@result} />
      </div>
      <p
        :if={@time_dependent}
        id={"#{@id}-daily"}
        class="flex items-start gap-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-arrow-path" class="mt-px size-3.5 shrink-0" />
        <span>
          {gettext(
            "Uses today's date (%{date}). Saved values are refreshed once a day, so published content moves to the new date overnight.",
            date: Date.to_iso8601(@today)
          )}
        </span>
      </p>
    </div>
    """
  end

  attr :result, :any, required: true

  defp preview_result(%{result: {:ok, value}} = assigns) do
    assigns = assign(assigns, value: display(value), kind: kind(value))

    ~H"""
    <div class="flex flex-wrap items-baseline gap-2">
      <output class="break-words font-mono text-base-content">{@value}</output>
      <span class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70">{@kind}</span>
    </div>
    """
  end

  defp preview_result(%{result: :blank} = assigns) do
    ~H"""
    <p class="text-base-content/60">
      {gettext("Empty for this document — the field is left blank.")}
    </p>
    """
  end

  defp preview_result(%{result: {:error, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <p class="flex items-center gap-2 text-error">
      <.icon name="hero-exclamation-triangle" class="size-4" />
      {gettext("The formula %{problem}.", problem: @message)}
    </p>
    """
  end

  defp preview_result(%{result: {:failed, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <p class="flex items-center gap-2 text-error">
      <.icon name="hero-exclamation-triangle" class="size-4" />
      {gettext("The formula fails on this document, so it would be saved blank: %{problem}",
        problem: @message
      )}
    </p>
    """
  end

  defp preview_result(assigns) do
    ~H"""
    <p class="text-base-content/60">{gettext("Build a formula to see what it works out to.")}</p>
    """
  end

  defp display(true), do: gettext("Yes")
  defp display(false), do: gettext("No")
  defp display(value), do: to_string(value)

  defp kind(value) when is_number(value), do: gettext("number")
  defp kind(value) when is_boolean(value), do: gettext("yes / no")
  defp kind(_value), do: gettext("text")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
