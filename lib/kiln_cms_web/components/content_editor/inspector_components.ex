defmodule KilnCMSWeb.ContentEditor.InspectorComponents do
  @moduledoc """
  Function components for the content editor's right inspector rail (Theme A):
  the tab strip and section cards, the Settings panel's building blocks
  (assignment/tasks, releases, document notes, tag picker, custom fields,
  featured image, social card) and the History/Preview panel pieces (#1311).

  Moved verbatim from `KilnCMSWeb.ContentEditorLive`. Events stay untargeted,
  so they keep landing on the enclosing LiveView, and nothing here introduces
  a `<form>` — the whole rail renders inside the page's own editor form, where
  the HTML parser silently drops a nested one.
  """

  use KilnCMSWeb, :html

  import KilnCMSWeb.BlockDiscussionComponents, only: [comment_card: 1]

  import KilnCMSWeb.ContentEditor.Shared,
    only: [blank_to_nil: 1, selected_tag_ids: 2, user_label: 1, with_counts: 2]

  # Whether this record currently carries a passphrase (#496). Derived from the
  # record rather than kept as an assign, so it cannot go stale against a save —
  # the rail only ever needs to know *that* one is set, never what it is.
  def content_locked?(record), do: not is_nil(Map.get(record || %{}, :access_password_hash))
  # Options for the pick-list custom fields; other field types need none.
  def custom_field_options(%{field_type: :media}, media, _refs),
    do: Enum.map(media, &{&1.filename, &1.id})

  def custom_field_options(%{field_type: :reference, name: name}, _media, refs),
    do: Map.get(refs, name, [])

  def custom_field_options(_definition, _media, _refs), do: []
  # Why the intelligence panel came back empty.
  #
  # "Publish this page to index it" used to be one of the answers, and it is
  # gone because it stopped being true (#852): an unpublished anchor now has its
  # centroid computed in memory, so a never-published draft compares like any
  # other document. What is left is the operator's setting, and genuinely
  # finding nothing.
  def intel_empty_reason(record) do
    if KilnCMS.Search.semantic?() do
      empty_document_reason(record)
    else
      gettext("Semantic search is off, so there is nothing to compare against.")
    end
  end

  # An empty document has no block text to embed, so there is nothing to compare
  # *from* — distinct from comparing and finding nothing, and fixable by writing
  # something rather than by waiting.
  defp empty_document_reason(record) do
    if blank_document?(record) do
      gettext("Add some content — suggestions come from what this page says.")
    else
      gettext("Nothing similar found.")
    end
  end

  # Shares `BlockIndexer`'s projection rather than re-deriving "has any text":
  # the question the panel is answering is "was there anything to embed", and
  # the answer has to be the one the embedder would give. It also handles an
  # unloaded `blocks` without raising.
  defp blank_document?(record), do: KilnCMS.Search.BlockIndexer.embedding_inputs(record) == []

  # Why the suggestion list came back empty — an unexplained empty panel reads
  # as broken. Same #852 change: the anchor no longer has to be published for
  # its neighbours to be found, so "publish this page" is no longer the reason.
  # (Only the *neighbours* are still published-only, which is a property of the
  # reader-facing surface and not something the author can act on here.)
  # Semantic search is checked FIRST, unlike the duplicates panel. With it off,
  # `Seo.Links.candidates/2` falls back to a keyword search built from the title
  # and focus keyphrase, which never reads the blocks — so telling the author to
  # add content would be advice that changes nothing.
  def link_empty_reason(record) do
    cond do
      not KilnCMS.Search.semantic?() ->
        gettext("No related pages matched. Enabling semantic search improves these results.")

      blank_document?(record) ->
        gettext("Add some content — suggestions come from what this page says.")

      true ->
        gettext("No related pages found yet.")
    end
  end

  # Accessible tag picker (#153): a labeled checkbox group replacing the native
  # <select multiple> (no ⌘/Ctrl needed). Each tag is its own labeled control;
  # the array submits under the same `tag_ids[]` name the relationship expects.
  #
  # Tags are sectioned by their `TagGroup` — collapsible, alphabetical within a
  # section, with a client-side filter box — so a large vocabulary stays
  # scannable. Groups may be scoped to certain content types; groups that don't
  # apply to `kind` are omitted.
  attr :form, :any, required: true
  attr :tag_index, :any, required: true
  attr :record, :any, required: true
  attr :open_sections, :any, required: true
  attr :tag_query, :string, default: ""
  attr :tags_capped?, :boolean, default: false
  attr :tag_limit, :integer, default: 500

  def tag_picker(assigns) do
    # A **MapSet**, not a list (#528). Membership is tested three times per tag
    # — the checkbox, the section count, and the filter — and this component
    # re-renders on every `validate`, i.e. per keystroke anywhere in the form.
    selected = selected_tag_ids(assigns.form, assigns.record)

    # The skeleton — which tag sits in which section, and its downcased filter
    # key — is computed once per RECORD change (`refresh_tag_index/1`), not per
    # render. Only the per-section tick counts depend on `selected`, so only
    # they are recomputed here.
    sections = with_counts(assigns.tag_index.sections, selected)
    filtering? = assigns.tag_query != ""

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:sections, sections)
      |> assign(:filtering?, filtering?)
      # The checkboxes still post under `tag_ids[]`; `merge_tag_params/2`
      # rewrites that into `add_tag_ids`/`remove_tag_ids` at submit time, so the
      # wire name the browser posts and the argument the changeset takes are
      # deliberately not the same thing (#638).
      |> assign(:name, assigns.form[:tag_ids].name <> "[]")
      # Why an empty picker is empty, which is not one question but two, and the
      # difference is what the editor should do next (#524). `pickable` and
      # `sections` are narrowed independently — every tag in the org can sit in
      # groups scoped to *other* content types, with none of them on this record,
      # and then there are tags but nothing to show. The old guard keyed the
      # whole body on `pickable`, so that case rendered a legend, a filter box
      # and nothing else — no explanation, and no way to tell it from a bug.
      |> assign(
        :empty_reason,
        cond do
          assigns.tag_index.pickable? == false and not filtering? -> :no_tags
          sections == [] and filtering? -> :no_match
          sections == [] -> :none_apply
          true -> nil
        end
      )

    ~H"""
    <fieldset id="tag-picker" phx-hook="TagFilter" data-tag-filter>
      <legend class="mb-1 block text-sm font-medium text-base-content">{gettext("Tags")}</legend>
      <p :if={@empty_reason == :no_tags} class="text-xs text-base-content/70">
        {gettext("No tags yet.")}
      </p>
      <%!-- Says only what is observable. `tag_sections/5` drops an *applicable*
            group that happens to be empty exactly as it drops a non-applicable
            one, so "every group is scoped to other types" would be wrong about
            as often as it was right — and would send the editor hunting for a
            scope to widen when the fix is a tag to create. The link goes where
            both fixes live; same shape as the media picker's empty state. --%>
      <p :if={@empty_reason == :none_apply} class="text-xs text-base-content/70">
        {gettext("No tags are available on this content type — set them up under")} <.link
          navigate={~p"/editor/taxonomy"}
          class="underline"
        >{gettext("taxonomy")}</.link>.
      </p>

      <div :if={@sections != [] or @filtering?} class="space-y-2">
        <%!-- Unnamed so it never serializes into the changeset, and wrapped in
              phx-update="ignore" so a re-render can't clobber what's typed.
              The TagFilter hook stops form propagation and pushes `filter_tags`
              (#1149) — the vocabulary is capped at mount, so the box has to
              round-trip to search beyond the window. --%>
        <div phx-update="ignore" id="tag-picker-filter">
          <input
            type="search"
            data-tag-filter-input
            placeholder={gettext("Filter tags…")}
            aria-label={gettext("Filter tags")}
            autocomplete="off"
            class="field-input w-full"
          />
        </div>

        <p :if={@tags_capped? and not @filtering?} class="text-xs text-base-content/60">
          {gettext(
            "Showing the first %{limit} tags. Filter to find others.",
            limit: @tag_limit
          )}
        </p>

        <%!-- `open` comes from a set judged once per section, never from the
              live tick count — see `refresh_tag_index/1`. While filtering, every
              section that still has tags is force-opened so hits are visible;
              clearing the query restores `@open_sections` (plus any section
              that gained a tick while open — see `filter_tags`). --%>
        <%!-- The id is load-bearing, not a handle: without one morphdom pairs
              these positionally, so a section appearing mid-list (a group that
              was empty at mount gaining an attached tag) shifts every section
              below it onto its neighbour's node — carrying that node's `open`,
              its `data-server-open` baseline and its filter-hook bookkeeping
              onto the wrong group. --%>
        <details
          :for={section <- @sections}
          id={tag_section_id(section.key)}
          data-tag-section
          open={@filtering? or MapSet.member?(@open_sections, section.key)}
          class="rounded border border-base-content/15"
        >
          <summary class="cursor-pointer px-2 py-1.5 text-sm font-medium">
            {section.label}
            <span class="font-normal text-base-content/60">
              ({gettext("%{selected} of %{total}",
                selected: section.selected_count,
                total: length(section.tags)
              )})
            </span>
          </summary>
          <p :if={section.note} class="px-2 pb-1 text-xs text-base-content/60">{section.note}</p>
          <div class="flex flex-wrap gap-2 p-2 pt-1">
            <label
              :for={tag <- section.tags}
              data-tag-item={tag.filter}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded border border-base-content/20 px-2 py-1 text-sm hover:bg-base-200"
            >
              <input
                type="checkbox"
                name={@name}
                value={tag.id}
                checked={MapSet.member?(@selected, tag.id)}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {tag.name}
            </label>
          </div>
        </details>

        <p :if={@empty_reason == :no_match} class="text-xs text-base-content/70">
          {gettext("No tags match that filter.")}
        </p>
      </div>
    </fieldset>
    """
  end

  defp tag_section_id({:group, id}), do: "tag-section-group-#{id}"
  defp tag_section_id(key) when is_atom(key), do: "tag-section-#{key}"
  # Featured-image chooser (#154): a thumbnail of the current selection plus a
  # button that opens the searchable media picker, replacing a <select> that
  # loaded every asset. The id is carried in a hidden input so it still submits.
  # One input for an admin-defined custom field (KilnCMS.CMS.FieldDefinition).
  # Inputs are named into the content form's `custom_fields` map
  # (`form[custom_fields][<name>]`); the write change coerces/validates them.
  attr :definition, :map, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :errors, :list, default: []
  attr :options, :list, default: []

  # Media / reference pick-lists: the select posts the target id; the stored
  # value is the write-time snapshot map (see ApplyCustomFields), so the
  # current selection is its "id".
  def custom_field_input(%{definition: %{field_type: type}} = assigns)
      when type in [:media, :reference] do
    assigns = assign(assigns, :selected_id, snapshot_id(assigns.value))

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={{label, id} <- @options} value={id} selected={@selected_id == id}>
          {label}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  def custom_field_input(%{definition: %{field_type: :boolean}} = assigns) do
    assigns = assign(assigns, :checked, assigns.value in [true, "true", "1", "on"])

    ~H"""
    <div>
      <label class="flex items-center gap-2 text-sm">
        <%!-- hidden "false" first so an unchecked box still submits a value (last wins) --%>
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && cf_errors_id(@definition)}
        />
        <span class="font-medium">{@definition.label}</span>
        <span :if={@definition.help_text} class="text-base-content/60">— {@definition.help_text}</span>
      </label>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  def custom_field_input(%{definition: %{field_type: :select}} = assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={opt <- @definition.options} value={opt} selected={to_string(@value) == opt}>
          {opt}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  def custom_field_input(%{definition: %{field_type: :text}} = assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <textarea
        id={cf_id(@definition)}
        name={@name}
        required={@definition.required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-input"
      >{@value}</textarea>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  # Everything else is registry-driven. A composite field type
  # (`Kiln.FieldType` declaring `input_parts/1`, e.g. `:geolocation`) renders a
  # labelled input per part; anything else renders a single `<input>`.
  def custom_field_input(assigns) do
    case field_type_parts(assigns.definition) do
      [] -> scalar_custom_field_input(assigns)
      parts -> composite_custom_field_input(assign(assigns, :parts, parts))
    end
  end

  # The composite parts a field type declares, or `[]` for core/scalar types.
  # `input_parts/1` is optional on `Kiln.FieldType` (a hand-rolled `@behaviour`
  # module from an out-of-tree plugin may predate it), so fall back to a scalar
  # input rather than crashing on an undefined function.
  #
  # `Code.ensure_loaded?/1` is not optional here: `function_exported?/3` answers
  # false for a module that is compiled but not yet *loaded*, and nothing loads
  # a field-type module at runtime — the registry is built at compile time and
  # only carries the atom. Without it, the first editor render after boot
  # silently degrades a composite field to a single text input, and submitting
  # that input wipes the stored value.
  defp field_type_parts(definition) do
    with module when not is_nil(module) <- KilnCMS.CMS.FieldTypes.get(definition.field_type),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :input_parts, 1) do
      module.input_parts(definition)
    else
      _no_parts -> []
    end
  end

  # Each part is named into the field's own map —
  # `…[custom_fields][<field>][<part>]` — so the whole map arrives at `cast/2`
  # as a unit. A fieldset rather than a label, because the group has several
  # controls and only the legend names them all.
  defp composite_custom_field_input(assigns) do
    ~H"""
    <fieldset aria-required={@definition.required && "true"}>
      <legend class="mb-1 block text-sm font-medium">{@definition.label}</legend>
      <div class="grid grid-cols-2 gap-2">
        <div :for={part <- @parts}>
          <.composite_part
            definition={@definition}
            part={part}
            name={@name}
            value={@value}
            errors={@errors}
          />
        </div>
      </div>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </fieldset>
    """
  end

  # A boolean part (`type: "checkbox"`) is not a text input with a different
  # `type=`. On a checkbox `value=` is what gets *submitted*, not what is
  # *checked* — binding the stored value there means a saved `all_day: true`
  # reopens unchecked, and a stored `false` renders `value="false"`, so ticking
  # the box submits the string "false" and the flag can never be turned on.
  #
  # So: a fixed `value="true"` and `checked` from the stored value.
  #
  # And deliberately **no** hidden `false` companion, which is the usual Phoenix
  # pairing. `ApplyCustomFields.blank_for?/2` calls a composite field empty when
  # every part is blank, and `"false"` is not blank — so the companion made an
  # untouched widget look filled-in, and an *optional* `datetime_range` field
  # made every document of its type unsaveable with "start is required". An
  # absent key already means false to `cast/2`, so unticking needs nothing.
  defp composite_part(%{part: %{type: "checkbox"}} = assigns) do
    ~H"""
    <label class="mt-5 flex items-center gap-2 text-xs text-base-content/70">
      <input
        id={cf_part_id(@definition, @part)}
        type="checkbox"
        name={"#{@name}[#{@part.key}]"}
        value="true"
        checked={composite_part_checked?(@value, @part.key)}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="size-4 rounded border border-base-content/30 accent-primary"
        {Map.get(@part, :attrs, %{})}
      />
      {@part.label}
    </label>
    """
  end

  defp composite_part(assigns) do
    ~H"""
    <label for={cf_part_id(@definition, @part)} class="mb-0.5 block text-xs text-base-content/70">
      {@part.label}
    </label>
    <input
      id={cf_part_id(@definition, @part)}
      type={Map.get(@part, :type, "text")}
      name={"#{@name}[#{@part.key}]"}
      value={composite_part_value(@value, @part.key)}
      required={@definition.required && Map.get(@part, :required?, true)}
      aria-invalid={@errors != [] && "true"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
      class="field-input"
      {Map.get(@part, :attrs, %{})}
    />
    """
  end

  # The same spellings `Kiln.FieldType` implementations accept, because a value
  # arrives here either fresh from the form (a string) or round-tripped out of
  # jsonb (a boolean).
  defp composite_part_checked?(value, key) do
    case composite_part_value(value, key) do
      true -> true
      binary when is_binary(binary) -> String.downcase(binary) in ~w(true 1 on yes)
      _other -> false
    end
  end

  # A plain `<input>`. Plugin and built-in field types (`Kiln.FieldType`) pick
  # their HTML input kind + extra attributes (min/max/step/readonly/…) via the
  # registry; core types map below.
  defp scalar_custom_field_input(assigns) do
    definition = assigns.definition

    {input_type, extra} =
      case KilnCMS.CMS.FieldTypes.get(definition.field_type) do
        nil -> {custom_input_type(definition.field_type), %{}}
        module -> {module.input_type(), module.input_attrs(definition)}
      end

    extra =
      if input_type == "number" and definition.field_type == :float,
        do: Map.put_new(extra, :step, "any"),
        else: extra

    assigns = assigns |> assign(:input_type, input_type) |> assign(:extra, extra)

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <input
        id={cf_id(@definition)}
        type={@input_type}
        name={@name}
        value={@value}
        required={@definition.required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-input"
        {@extra}
      />
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  attr :definition, :map, required: true
  attr :errors, :list, required: true

  defp custom_field_errors_list(assigns) do
    ~H"""
    <div :if={@errors != []} id={cf_errors_id(@definition)}>
      <p :for={message <- @errors} class="mt-1 flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-4" /> {message}
      </p>
    </div>
    """
  end

  defp cf_id(definition), do: "custom-field-#{definition.name}"
  defp cf_errors_id(definition), do: "custom-field-#{definition.name}-errors"
  defp cf_part_id(definition, part), do: "custom-field-#{definition.name}-#{part.key}"

  # One part of a composite value: the stored/mid-edit map's entry for that key.
  # The value may still be the raw param map during a validate round-trip, so
  # accept string keys only (jsonb and form params both give strings).
  defp composite_part_value(value, key) when is_map(value), do: Map.get(value, key)
  defp composite_part_value(_value, _key), do: nil

  # The current selection for a pick-list field: the stored snapshot's id, or
  # the raw id while a change is mid-validate.
  defp snapshot_id(%{"id" => id}), do: id
  defp snapshot_id(id) when is_binary(id) and id != "", do: id
  defp snapshot_id(_other), do: nil

  defp custom_input_type(:integer), do: "number"
  defp custom_input_type(:float), do: "number"
  defp custom_input_type(:date), do: "date"
  defp custom_input_type(:datetime), do: "datetime-local"
  defp custom_input_type(:url), do: "url"
  defp custom_input_type(_), do: "text"
  attr :tasks, :list, required: true
  attr :open?, :boolean, required: true
  attr :draft, :map, required: true
  attr :assignable_users, :list, required: true
  attr :auto_complete_default, :boolean, required: true

  # Editorial tasks (#501): the whole record's open tasks (usually zero or
  # one — v1 doesn't cap it), plus an inline "+ Assign" form. Document-level,
  # not block-level (unlike `comment_panel/1` below) — a task is "who owns
  # getting this whole piece of content done," not feedback on one block.
  #
  # No `<form>` here, same reason `comment_panel/1` avoids one (see its own
  # moduledoc note): this whole section lives inside the page's own
  # `id="page-editor"` form, and HTML doesn't allow nested forms — a nested
  # `<form phx-submit=…>` silently gets dropped by the parser (its child
  # inputs survive, the tag itself vanishes), so `phx-submit` never fires.
  # Each field tracks its own `phx-change` into `@draft`; the submit button
  # is a plain `phx-click` reading that assign server-side.
  def task_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <p :if={@tasks == []} class="text-xs text-base-content/60">
        {gettext("No open tasks.")}
      </p>

      <ul :if={@tasks != []} class="space-y-2">
        <li :for={task <- @tasks} class="rounded border border-base-content/15 p-2 text-xs">
          <div class="flex items-center justify-between gap-2">
            <span class="font-medium">{user_label(task.assignee)}</span>
            <button
              type="button"
              phx-click="task_complete"
              phx-value-id={task.id}
              class="btn-link text-primary hover:underline"
            >
              {gettext("Mark done")}
            </button>
          </div>
          <p :if={task.due_on} class="text-base-content/60">
            {gettext("Due %{date}", date: Date.to_iso8601(task.due_on))}
          </p>
          <%!-- Shown only when this task DISAGREES with the site default
                (#818). An earlier version keyed on the raw field, which was
                silent in the case that most needs saying — a site set to
                "leave open" and a task inheriting it — while labelling a
                `false` task that merely agreed with the site. Asked through
                `TaskSettings` so the precedence rule lives in one module. --%>
          <p
            :if={task_overrides_site?(task, @auto_complete_default)}
            class="text-base-content/60"
          >
            {if task.auto_complete_on_publish,
              do: gettext("Completes when this publishes"),
              else: gettext("Stays open when this publishes")}
          </p>
          <p :if={task.note} class="mt-1 text-base-content/70">{task.note}</p>
        </li>
      </ul>

      <button
        :if={!@open?}
        type="button"
        phx-click="task_assign_open"
        class="btn btn-sm btn-default"
      >
        {gettext("+ Assign")}
      </button>

      <div :if={@open?} class="space-y-2 rounded border border-base-content/15 p-2">
        <select name="task_assignee_id" phx-change="task_draft_change" class="field-select py-1">
          <option value="">{gettext("Assign to…")}</option>
          <option
            :for={{label, id} <- @assignable_users}
            value={id}
            selected={@draft["assignee_id"] == id}
          >
            {label}
          </option>
        </select>
        <input
          type="date"
          name="task_due_on"
          phx-change="task_draft_change"
          value={@draft["due_on"]}
          class="input input-sm w-full"
        />
        <textarea
          name="task_note"
          phx-change="task_draft_change"
          phx-debounce="blur"
          placeholder={gettext("Note (optional)")}
          class="textarea textarea-sm w-full"
        >{@draft["note"]}</textarea>
        <%!-- Three values, not a checkbox (#818): the blank option means "use
              whatever the site is set to", which is different from an explicit
              yes and from an explicit no. A checkbox could only say two of
              those, and would have to pick one to mean "inherit". --%>
        <select
          name="task_auto_complete"
          phx-change="task_draft_change"
          class="field-select py-1"
        >
          <option value="" selected={@draft["auto_complete"] in [nil, ""]}>
            {if @auto_complete_default,
              do: gettext("On publish: complete it (site default)"),
              else: gettext("On publish: leave it open (site default)")}
          </option>
          <option value="true" selected={@draft["auto_complete"] == "true"}>
            {gettext("On publish: always complete it")}
          </option>
          <option value="false" selected={@draft["auto_complete"] == "false"}>
            {gettext("On publish: always leave it open")}
          </option>
        </select>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="task_assign_close" class="btn btn-sm btn-default">
            {gettext("Cancel")}
          </button>
          <button type="button" phx-click="task_assign_submit" class="btn btn-sm btn-primary">
            {gettext("Assign")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, default: nil
  attr :release, :map, default: nil
  attr :releases, :list, required: true
  attr :draft, :map, required: true

  # Content releases (#500 / #836): which release this record is queued in, or a
  # picker to put it in one — the editor-side half of "add to release", which
  # until now existed only as a bulk action on the content list.
  #
  # No `<form>`, for the reason `task_list/1` and `comment_panel/1` spell out:
  # this renders inside the page's own `id="page-editor"` form, HTML forbids
  # nested forms, and the parser silently drops the tag (keeping its inputs), so
  # `phx-submit` would never fire and the button would appear to do nothing.
  def release_panel(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if @item do %>
        <div class="rounded border border-base-content/15 p-2 text-xs">
          <p class="font-medium">
            <.link :if={@release} navigate={~p"/editor/releases/#{@release.id}"} class="link">
              {@release.name}
            </.link>
            <span :if={!@release}>{gettext("In a release")}</span>
          </p>
          <p class="mt-1 text-base-content/70">
            {if @item.action == :unpublish,
              do: gettext("Will be unpublished when the release goes live."),
              else: gettext("Will be published when the release goes live.")}
          </p>
          <button
            type="button"
            phx-click="release_remove"
            class="btn-link mt-2 text-primary hover:underline"
          >
            {gettext("Remove from release")}
          </button>
        </div>
      <% else %>
        <p :if={@releases == []} class="text-xs text-base-content/60">
          {gettext("No open releases.")}
          <.link navigate={~p"/editor/releases"} class="link">{gettext("Create one")}</.link>
        </p>

        <div :if={@releases != []} class="space-y-2">
          <select
            name="release_target"
            phx-change="release_draft_change"
            aria-label={gettext("Release")}
            class="field-select py-1"
          >
            <option
              :for={release <- @releases}
              value={release.id}
              selected={@draft["release_id"] == release.id}
            >
              {release.name}
            </option>
          </select>
          <select
            name="release_action"
            phx-change="release_draft_change"
            aria-label={gettext("On go-live")}
            class="field-select py-1"
          >
            <option value="publish" selected={@draft["action"] != "unpublish"}>
              {gettext("Publish on go-live")}
            </option>
            <option value="unpublish" selected={@draft["action"] == "unpublish"}>
              {gettext("Unpublish on go-live")}
            </option>
          </select>
          <button type="button" phx-click="release_add" class="btn btn-sm btn-default w-full">
            {gettext("Add to release")}
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr :comments, :list, required: true

  # Document-level comment threads (#946): findings from an editorial-
  # intelligence reaction with no single block to anchor to
  # (`flag_duplicates`, `suggest_metadata`) land here — `block_id: nil`,
  # grouped by `RouteToBlockThread` the same way a block's comments are.
  # Read-only from a human's side today: automation is the only writer of a
  # `block_id: nil` comment, so there is no compose form, only
  # resolve/unresolve on each thread's root (shared with
  # `KilnCMSWeb.BlockDiscussionComponents.block_discussion/1`'s
  # `comment_resolve`/`comment_unresolve` events, which key on comment id and
  # so work here unchanged).
  #
  # Grouped by thread, not rendered as one flat list: a resolved document-
  # level root starts a fresh thread rather than being reopened
  # (`RouteToBlockThread`'s moduledoc), so a document can carry more than one
  # of these at once, and without grouping a reply to one thread would render
  # indistinguishably next to another thread's root (#1252 review).
  def document_comment_panel(assigns) do
    threads = document_threads(assigns.comments)
    assigns = assign(assigns, :threads, threads)

    ~H"""
    <div class="space-y-4">
      <p :if={@threads == []} class="text-xs text-base-content/60">
        {gettext("No document-level comments.")}
      </p>

      <div :for={thread <- @threads} class="space-y-2">
        <div :for={comment <- thread} class="rounded border border-base-content/15 p-2 text-xs">
          <.comment_card comment={comment} />
        </div>
      </div>
    </div>
    """
  end

  # `comments` arrives sorted oldest-first (`CMS.list_comments_for!`'s
  # `:for_content` action), so each thread's own comment list is already root-
  # first and `List.first/1` is that thread's root — grouping by `thread_id ||
  # id` (a reply's `thread_id` is its root's id; a root's own is nil) sorts
  # threads themselves oldest-root-first too.
  defp document_threads(comments) do
    comments
    |> Enum.filter(&is_nil(&1.block_id))
    |> Enum.group_by(&(&1.thread_id || &1.id))
    |> Map.values()
    |> Enum.sort_by(&(&1 |> List.first() |> Map.get(:inserted_at)))
  end

  attr :form, :any, required: true
  attr :media, :list, required: true
  attr :current_org, :any, required: true

  # How a shared link to this page will look (#476).
  #
  # The fallbacks here mirror `KilnCMSWeb.ContentController.render_content_body/6`
  # exactly — title falls back to `title`, description and image do **not** fall
  # back at all. A preview that flattered the record by inventing fallbacks
  # delivery doesn't have would be worse than no preview.
  def social_card(assigns) do
    image = AshPhoenix.Form.value(assigns.form, :seo_image)
    title = AshPhoenix.Form.value(assigns.form, :seo_title)
    fallback_title = AshPhoenix.Form.value(assigns.form, :title)

    assigns =
      assigns
      |> assign(:card_image, blank_to_nil(image))
      |> assign(:card_title, blank_to_nil(title) || blank_to_nil(fallback_title))
      |> assign(
        :card_description,
        blank_to_nil(AshPhoenix.Form.value(assigns.form, :seo_description))
      )
      |> assign(:card_host, public_host(assigns.current_org))

    ~H"""
    <div>
      <span class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Social preview")}
      </span>
      <div class="overflow-hidden rounded border border-base-content/15">
        <img
          :if={@card_image}
          src={@card_image}
          alt=""
          class="aspect-[1.91/1] w-full bg-base-200 object-cover"
        />
        <div
          :if={!@card_image}
          class="flex aspect-[1.91/1] w-full items-center justify-center bg-base-200 text-xs text-base-content/50"
        >
          {gettext("No social image")}
        </div>
        <div class="space-y-0.5 border-t border-base-content/10 p-2">
          <p class="text-xs uppercase text-base-content/50">{@card_host}</p>
          <p class="truncate text-sm font-medium">
            {@card_title || gettext("Untitled")}
          </p>
          <p class="line-clamp-2 text-xs text-base-content/70">
            {@card_description || gettext("No description — search engines will write their own.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  def task_overrides_site?(task, site_default) do
    case KilnCMS.CMS.TaskSettings.describe(task, site_default) do
      {^site_default, _source} -> false
      {_effective, :task} -> true
      {_effective, :site} -> false
    end
  end

  defp public_host(org) do
    case URI.parse(KilnCMSWeb.Tenant.base_url(org)) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  attr :form, :any, required: true
  attr :media, :list, required: true

  def featured_image_field(assigns) do
    id = AshPhoenix.Form.value(assigns.form, :featured_image_id)

    assigns =
      assigns
      |> assign(:field, assigns.form[:featured_image_id])
      |> assign(:selected, Enum.find(assigns.media, &(to_string(&1.id) == to_string(id))))

    ~H"""
    <div>
      <span class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Featured image")}
      </span>
      <input type="hidden" name={@field.name} value={@field.value} />
      <div class="mt-1 flex flex-wrap items-center gap-3">
        <img
          :if={@selected}
          src={@selected.url}
          alt=""
          class="h-16 w-16 rounded border border-base-content/10 object-cover"
        />
        <span class="text-sm text-base-content/70">
          {(@selected && @selected.filename) || gettext("None selected")}
        </span>
        <button
          type="button"
          phx-click="open_featured_picker"
          class="btn btn-sm btn-default"
        >
          {gettext("Choose from library")}
        </button>
        <button
          :if={@selected}
          type="button"
          phx-click="clear_featured"
          class="text-sm text-base-content/70 hover:text-error"
        >
          {gettext("Remove")}
        </button>
      </div>
    </div>
    """
  end

  # Pick-for-comparison toggle on a version-history row.
  #
  # A `<button>` with checkbox semantics rather than an `<input type="checkbox">`:
  # this sits inside the main `<.form>`, where even an unnamed input's change
  # event bubbles up and fires the form's `phx-change` (see the tag filter's note
  # above), which would run validation and mark the draft dirty on every pick.
  attr :pick, :string, required: true
  attr :picked, :boolean, required: true
  attr :label, :string, required: true

  def compare_toggle(assigns) do
    ~H"""
    <button
      type="button"
      role="checkbox"
      aria-checked={to_string(@picked)}
      aria-label={gettext("Compare %{version}", version: @label)}
      phx-click="toggle_compare"
      phx-value-version_id={@pick}
      class={[
        "flex size-4 shrink-0 items-center justify-center rounded border",
        (@picked && "border-primary bg-primary text-primary-content") ||
          "border-base-content/30 hover:border-base-content/60"
      ]}
    >
      <.icon :if={@picked} name="hero-check" class="size-3" />
    </button>
    """
  end

  # Tab strip for the right inspector rail (Theme A). Switching is pure view
  # state; the panels themselves stay mounted (toggled by CSS in render/1).
  # `settings_alert` raises a dot on the Settings tab so validation errors in a
  # hidden panel still get noticed.
  attr :tab, :atom, required: true
  attr :settings_alert, :boolean, default: false

  def inspector_tabs(assigns) do
    ~H"""
    <div
      role="tablist"
      aria-label={gettext("Inspector")}
      class="flex items-center gap-1 rounded-lg bg-base-200/60 p-1 text-sm"
    >
      <button
        :for={
          {id, label, icon, alert} <- [
            {:preview, gettext("Preview"), "hero-eye", false},
            {:settings, gettext("Settings"), "hero-adjustments-horizontal", @settings_alert},
            {:history, gettext("History"), "hero-clock", false}
          ]
        }
        type="button"
        role="tab"
        aria-selected={to_string(@tab == id)}
        phx-click="switch_inspector_tab"
        phx-value-tab={id}
        class={[
          "flex flex-1 items-center justify-center gap-1.5 rounded-md px-3 py-1.5 font-medium transition",
          (@tab == id && "bg-base-100 text-base-content shadow-sm") ||
            "text-base-content/60 hover:text-base-content"
        ]}
      >
        <.icon name={icon} class="size-4" />
        <span>{label}</span>
        <span
          :if={alert}
          class="size-1.5 rounded-full bg-error"
          title={gettext("This panel has validation errors")}
        ></span>
      </button>
    </div>
    """
  end

  # A titled card inside an inspector panel (Theme A). Replaces the old buried
  # `<details>` accordions with an always-expanded, clearly-labelled section —
  # the panel's tab already gates visibility, so no per-section collapsing.
  attr :title, :string, required: true
  attr :id, :string, default: nil
  # Optional trailing content on the heading row — a status pill or counter that
  # belongs with the title rather than in the body.
  slot :aside
  slot :inner_block, required: true

  def inspector_section(assigns) do
    ~H"""
    <section id={@id} class="rounded-lg border border-base-content/10 p-4">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {@title}
        </h3>
        <span :if={@aside != []}>{render_slot(@aside)}</span>
      </div>
      <div class="space-y-3">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  # The live preview article (title + rendered blocks). The previewed title is an
  # h2 so the editor keeps a single logical h1 (#174). Each block is a `{id, html}`
  # pair: it renders inside a `.kiln-block` (so it picks up the delivered typography)
  # wrapped in a hover target that reveals an "Edit" jump into the in-context editor
  # focused on that block (Theme C — the preview is a launch point for visual
  # editing). `@html` blocks with a nil id (legacy) render without the jump.
  attr :form, :any, required: true
  attr :html, :any, required: true
  attr :kind, :atom, required: true
  attr :slug, :string, required: true

  def preview_article(assigns) do
    ~H"""
    <article class="prose max-w-none space-y-3 rounded border border-base-content/15 p-5">
      <h2 class="text-2xl font-bold">{@form[:title].value}</h2>
      <div
        :for={{id, html} <- @html}
        class="group relative -mx-2 rounded px-2 transition hover:bg-base-200/40"
      >
        <div class="kiln-block">{html}</div>
        <.link
          :if={id}
          navigate={~p"/editor/site/#{@kind}/#{@slug}?#{[focus: id]}"}
          class="absolute right-1 top-1 z-10 hidden items-center gap-1 rounded bg-base-100/95 px-1.5 py-0.5 text-xs font-medium text-base-content no-underline shadow ring-1 ring-base-content/10 group-hover:inline-flex"
          title={gettext("Edit this block on the page")}
        >
          <.icon name="hero-pencil-square" class="size-3" />{gettext("Edit")}
        </.link>
      </div>
    </article>
    """
  end
end
