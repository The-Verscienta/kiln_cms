defmodule KilnCMSWeb.ContentEditor.InspectorComponents do
  @moduledoc """
  Function components for the content editor's right inspector rail (Theme A):
  the tab strip and section cards, the Settings panel's building blocks
  (assignment/tasks, releases, document notes, tag picker, custom field inputs,
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

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMSWeb.ContentEditor.GroupRows

  require Logger

  # Whether this record currently carries a passphrase (#496). Derived from the
  # record rather than kept as an assign, so it cannot go stale against a save —
  # the rail only ever needs to know *that* one is set, never what it is.
  def content_locked?(record), do: not is_nil(Map.get(record || %{}, :access_password_hash))
  # Options for the media custom fields; other field types need none (a
  # reference searches its target itself — `ReferencePicker`). A gallery takes
  # the library rows themselves: it renders thumbnails, and a just-picked id
  # whose snapshot hasn't resolved yet looks its url up here.
  # Both media shapes take the library rows themselves: they render thumbnails,
  # and a just-picked id whose snapshot hasn't resolved yet looks its url up here.
  def custom_field_options(%{field_type: :media}, media), do: media

  def custom_field_options(_definition, _media), do: []
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
  # Whether the editor may add a tag from the filter box (#1805) — the
  # `CMS.can_create_tag?/3` answer, so a role the Taxonomy policies refuse is
  # never offered a button that would only fail.
  attr :can_create?, :boolean, default: false

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
      # "Create tag “…”" (#1805) is offered while the query names no tag the
      # picker is showing. A name that does exist elsewhere (a group scoped to
      # another type) is still safe to submit: the server ticks that tag
      # rather than making a second one.
      |> assign(
        :offer_create?,
        assigns.can_create? and filtering? and not exact_tag?(sections, assigns.tag_query)
      )
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
        {if @can_create?,
          do: gettext("No tags yet. Type a name below to add one."),
          else: gettext("No tags yet.")}
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
        <span :if={@can_create?}>{gettext("Or type a name below to add one.")}</span>
      </p>

      <div :if={@sections != [] or @filtering? or @can_create?} class="space-y-2">
        <%!-- Unnamed so it never serializes into the changeset, and wrapped in
              phx-update="ignore" so a re-render can't clobber what's typed.
              The TagFilter hook stops form propagation and pushes `filter_tags`
              (#1149) — the vocabulary is capped at mount, so the box has to
              round-trip to search beyond the window. --%>
        <div phx-update="ignore" id="tag-picker-filter">
          <input
            type="search"
            data-tag-filter-input
            placeholder={
              if @can_create?, do: gettext("Find or add a tag…"), else: gettext("Filter tags…")
            }
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

        <p
          :if={@empty_reason == :no_match and not @offer_create?}
          class="text-xs text-base-content/70"
        >
          {gettext("No tags match that filter.")}
        </p>

        <%!-- Inline create (#1805). Enter in the filter box does the same
              (the TagFilter hook). Only the tag is created here; it is ticked
              like any other, and reaches the entry on Save. --%>
        <button
          :if={@offer_create?}
          type="button"
          id="tag-picker-create"
          phx-click="create_tag"
          phx-value-name={@tag_query}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Create tag “%{name}”", name: @tag_query)}
        </button>
      </div>
    </fieldset>
    """
  end

  defp exact_tag?(sections, query) do
    wanted = query |> String.trim() |> String.downcase()
    Enum.any?(sections, fn section -> Enum.any?(section.tags, &(&1.filter == wanted)) end)
  end

  @doc """
  Where this document sits in the content tree (#1597, D21).

  A plain select with its own `phx-change`, never a field on the editor's form:
  `parent_id` is not in `default_accept`, because a move is its own action
  (`:move`). So choosing here **writes immediately** rather than waiting for
  Save — which is why the hint says so, and why the options are only ever ones
  the write would accept (`KilnCMS.CMS.ContentTree.candidate_parents/3` does the
  same arithmetic the validation does).

  Hidden entirely for an unsaved draft: there is no record to move yet.
  """
  attr :options, :list, required: true
  attr :current_id, :string, default: nil
  # Ancestors, root first — where the document sits now.
  attr :path, :list, default: []
  attr :persisted?, :boolean, default: true

  def parent_field(assigns) do
    ~H"""
    <div :if={@persisted?} id="parent-field" class="space-y-2">
      <label for="parent-select" class="field-label">{gettext("Parent")}</label>

      <select
        id="parent-select"
        name="parent_id"
        phx-change="move_parent"
        class="field-select py-1"
      >
        <option value="" selected={is_nil(@current_id)}>
          {gettext("— No parent (top level) —")}
        </option>
        <option :for={option <- @options} value={option.id} selected={@current_id == option.id}>
          {String.duplicate("— ", option.depth - 1)}{option.title}
        </option>
      </select>

      <p :if={@path != []} class="text-xs text-base-content/60">
        {gettext("In:")} {Enum.map_join(@path, " / ", & &1.title)}
      </p>

      <p class="text-xs text-base-content/60">
        {gettext("Moving a document saves straight away, without waiting for Save.")}
      </p>
    </div>
    """
  end

  # The Category select, plus "New category" (#1805): a small inline name field
  # that creates the category and selects it. Plain inputs with their own
  # `phx-change`/`phx-click`, never a nested `<form>` — this renders inside the
  # editor's form (see `InspectorSettingsComponent`). The name field is named
  # outside `form[...]`, so it never reaches the changeset.
  attr :form, :any, required: true
  attr :categories, :list, required: true
  attr :can_create?, :boolean, default: false
  # `nil` while the inline field is closed; the typed name while it is open.
  attr :draft, :string, default: nil
  attr :error, :string, default: nil
  # A category the type shares across locales, on a translation (#1327,
  # #1860): shown, not editable. A select has no `readonly`, so it is disabled
  # and a hidden input carries the stored value, which re-sends it unchanged.
  attr :locked, :boolean, default: false

  def category_field(assigns) do
    ~H"""
    <div id="category-field" class="space-y-2">
      <input
        :if={@locked}
        type="hidden"
        name={@form[:category_id].name}
        value={@form[:category_id].value}
      />
      <.input
        field={@form[:category_id]}
        type="select"
        label={gettext("Category")}
        prompt={gettext("— None —")}
        options={Enum.map(@categories, &{&1.name, &1.id})}
        disabled={@locked}
      />

      <button
        :if={@can_create? and is_nil(@draft) and not @locked}
        type="button"
        id="category-new"
        phx-click="category_new_open"
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("New category")}
      </button>

      <div
        :if={@can_create? and is_binary(@draft)}
        id="category-new-field"
        phx-hook="InlineCreate"
        class="space-y-1"
      >
        <label for="category-new-name" class="block text-xs font-medium text-base-content/80">
          {gettext("New category name")}
        </label>
        <div class="flex items-center gap-2">
          <input
            type="text"
            id="category-new-name"
            name="new_category_name"
            value={@draft}
            phx-change="category_new_draft"
            phx-mounted={JS.focus()}
            data-inline-create-input
            autocomplete="off"
            aria-invalid={@error && "true"}
            aria-describedby={@error && "category-new-error"}
            class="field-input min-w-0 flex-1"
          />
          <button
            type="button"
            id="category-new-add"
            phx-click="create_category"
            class="btn btn-primary btn-sm"
          >
            {gettext("Add")}
          </button>
          <button
            type="button"
            id="category-new-cancel"
            phx-click="category_new_cancel"
            data-inline-create-cancel
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
        </div>
        <p :if={@error} id="category-new-error" class="text-xs text-error">{@error}</p>
      </div>
    </div>
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
  # What an empty `:fallback` field inherits (#1327), on the inputs that can
  # show it: the scalar `<input>` and the plain textarea.
  attr :placeholder, :string, default: nil

  # A gallery media field (`multiple: true`): the picked images as an ordered
  # strip of thumbnails, each carried by a hidden `name[]` input so the order on
  # screen is the order submitted. Images are added through the library drawer's
  # multi-select (`open_field_gallery_picker`), and moved or removed with the
  # buttons on each tile — all server-side edits of the form params, so the
  # strip never holds state the form doesn't.
  #
  # The leading blank `name[]` input is what makes an emptied gallery submit at
  # all: with no tiles there'd be no input, the key would be absent, and an
  # absent key keeps its stored value. `ApplyCustomFields` drops the blank.
  def custom_field_input(%{definition: %{field_type: :media, multiple: true}} = assigns) do
    items = gallery_items(assigns.value, assigns.options)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:last, length(items) - 1)

    ~H"""
    <div
      id={cf_id(@definition)}
      role="group"
      aria-labelledby={"#{cf_id(@definition)}-label"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{cf_id(@definition)}-label"} class="text-sm font-medium">
          {@definition.label}
        </span>
        <span :if={@items != []} class="text-xs text-base-content/60">
          {ngettext("%{count} image", "%{count} images", length(@items))}
        </span>
      </div>
      <input type="hidden" name={"#{@name}[]"} value="" />
      <ol
        :if={@items != []}
        id={"#{cf_id(@definition)}-items"}
        class="grid grid-cols-3 gap-2 sm:grid-cols-4 lg:grid-cols-6"
      >
        <li
          :for={{item, index} <- Enum.with_index(@items)}
          id={"cf-gallery-#{@definition.name}-#{item.id}"}
          class="group relative aspect-square overflow-hidden rounded-md border border-base-content/10 bg-base-200"
        >
          <input type="hidden" name={"#{@name}[]"} value={item.id} />
          <img
            :if={item.url}
            src={item.url}
            alt={item.alt || ""}
            loading="lazy"
            class="size-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
          />
          <span
            :if={!item.url}
            class="flex size-full items-center justify-center text-base-content/40"
          >
            <.icon name="hero-photo" class="size-6" />
          </span>
          <span class="absolute left-1 top-1 flex size-5 items-center justify-center rounded-full bg-base-100/90 text-[10px] font-semibold tabular-nums text-base-content shadow-sm">
            {index + 1}
          </span>
          <div class="absolute inset-x-0 bottom-0 flex items-center justify-between gap-0.5 bg-gradient-to-t from-black/60 to-transparent p-1 opacity-0 transition-opacity duration-150 group-hover:opacity-100 group-focus-within:opacity-100 pointer-coarse:opacity-100">
            <div class="flex gap-0.5">
              <button
                type="button"
                phx-click="field_gallery_move"
                phx-value-field={@definition.name}
                phx-value-id={item.id}
                phx-value-dir="up"
                disabled={index == 0}
                aria-label={gettext("Move image %{position} earlier", position: index + 1)}
                class="rounded p-0.5 text-white hover:bg-white/20 disabled:opacity-30"
              >
                <.icon name="hero-chevron-left" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="field_gallery_move"
                phx-value-field={@definition.name}
                phx-value-id={item.id}
                phx-value-dir="down"
                disabled={index == @last}
                aria-label={gettext("Move image %{position} later", position: index + 1)}
                class="rounded p-0.5 text-white hover:bg-white/20 disabled:opacity-30"
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </button>
            </div>
            <button
              type="button"
              phx-click="field_gallery_remove"
              phx-value-field={@definition.name}
              phx-value-id={item.id}
              aria-label={gettext("Remove image %{position}", position: index + 1)}
              class="rounded p-0.5 text-white hover:bg-error/80"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </li>
      </ol>
      <p :if={@items == []} class="text-sm text-base-content/60">
        {gettext("No images yet.")}
      </p>
      <button
        type="button"
        id={"#{cf_id(@definition)}-add"}
        phx-click="open_field_gallery_picker"
        phx-value-field={@definition.name}
        class="btn btn-sm btn-default mt-2"
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("Add images")}
      </button>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  # A single media field (#2054): a thumbnail of the current pick, and the
  # library drawer to change it — the featured image's shape, replacing a
  # `<select>` of filenames that listed only the editor's recent window. The id
  # rides in a hidden input, so the form posts what it always posted; picking
  # and removing are server-side edits of the form params
  # (`open_field_media_picker`, `clear_field_media`).
  #
  # Rendered from the stored snapshot, so an item older than the drawer's
  # window still shows; a raw id (a failed validate's params) borrows its url
  # from the window. A list (stored while the field was a gallery) shows its
  # first item — what saving it keeps.
  def custom_field_input(%{definition: %{field_type: :media}} = assigns) do
    assigns =
      assign(assigns, :item, assigns.value |> gallery_items(assigns.options) |> List.first())

    ~H"""
    <div
      id={cf_id(@definition)}
      role="group"
      aria-labelledby={"#{cf_id(@definition)}-label"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
    >
      <span id={"#{cf_id(@definition)}-label"} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </span>
      <input type="hidden" name={@name} value={(@item && @item.id) || ""} />
      <div class="flex flex-wrap items-center gap-3">
        <span class="flex size-16 shrink-0 items-center justify-center overflow-hidden rounded-md border border-base-content/10 bg-base-200 text-base-content/40">
          <img
            :if={@item && @item.url}
            src={@item.url}
            alt={@item.alt || ""}
            loading="lazy"
            class="size-full object-cover"
          />
          <.icon :if={!(@item && @item.url)} name="hero-photo" class="size-6" />
        </span>
        <span :if={!@item} class="text-sm text-base-content/70">{gettext("None selected")}</span>
        <button
          type="button"
          id={"#{cf_id(@definition)}-choose"}
          phx-click="open_field_media_picker"
          phx-value-field={@definition.name}
          class="btn btn-sm btn-default"
        >
          {if @item, do: gettext("Replace"), else: gettext("Choose from library")}
        </button>
        <button
          :if={@item}
          type="button"
          id={"#{cf_id(@definition)}-remove"}
          phx-click="clear_field_media"
          phx-value-field={@definition.name}
          class="text-sm text-base-content/70 hover:text-error"
        >
          {gettext("Remove")}
        </button>
      </div>
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

  # A list of phrases (`multiple` `:string` — symptoms, indications,
  # synonyms): one text input per item, each editable in place, removable and
  # dragged by its handle, plus an "add" box (`TermPicker` in lines mode) that
  # adds an item on Enter and splits a pasted block into one item per line.
  # No vocabulary and no suggestions: these lists run to hundreds of distinct
  # phrases. The inputs post `name[]` in screen order behind the same blank
  # sentinel as the tag picker. An item emptied in place keeps its row while
  # the form holds it (`list_items/1`) — dropping it on the next patch would
  # take the input out from under the author retyping it — and is dropped on
  # save.
  def custom_field_input(%{definition: %{field_type: :string, multiple: true}} = assigns) do
    items = list_items(assigns.value)

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:full?, full?(assigns.definition, length(items)))

    ~H"""
    <div
      id={cf_id(@definition)}
      role="group"
      aria-labelledby={"#{cf_id(@definition)}-label"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{cf_id(@definition)}-label"} class="text-sm font-medium">
          {@definition.label}
        </span>
        <span :if={@items != []} class="text-xs tabular-nums text-base-content/60">
          {ngettext("%{count} item", "%{count} items", length(@items))}
        </span>
      </div>
      <input type="hidden" name={"#{@name}[]"} value="" />
      <ol
        :if={@items != []}
        id={"#{cf_id(@definition)}-items"}
        phx-hook="Sortable"
        data-sort-event="list_item_reorder"
        data-sort-field={@definition.name}
        class="mb-1.5 space-y-1"
      >
        <li
          :for={{item, index} <- Enum.with_index(@items)}
          id={"cf-item-#{@definition.name}-#{index}"}
          data-sort-id={index}
          class="group flex items-center gap-1"
        >
          <span
            data-drag-handle
            title={gettext("Drag to reorder")}
            class="cursor-grab rounded p-1 text-base-content/30 transition-colors group-hover:text-base-content/60 active:cursor-grabbing"
          >
            <.icon name="hero-bars-2" class="size-3.5" />
          </span>
          <input
            type="text"
            id={"#{cf_id(@definition)}-#{index}"}
            name={"#{@name}[]"}
            value={item}
            aria-label={
              gettext("%{field}, item %{position}", field: @definition.label, position: index + 1)
            }
            class="field-input min-w-0 flex-1 py-1 text-sm"
          />
          <button
            type="button"
            phx-click="list_item_remove"
            phx-value-field={@definition.name}
            phx-value-index={index}
            aria-label={gettext("Remove item %{position}", position: index + 1)}
            class="rounded p-1 text-base-content/40 opacity-60 transition hover:bg-error/10 hover:text-error group-hover:opacity-100 focus-visible:opacity-100"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </li>
      </ol>
      <div :if={!@full?} class="flex items-center gap-1">
        <span class="p-1 text-base-content/30"><.icon name="hero-plus" class="size-3.5" /></span>
        <input
          type="text"
          id={"#{cf_id(@definition)}-entry"}
          phx-hook="TermPicker"
          data-field={@definition.name}
          data-count={length(@items)}
          data-split="lines"
          autocomplete="off"
          enterkeyhint="enter"
          placeholder={gettext("Add an item…")}
          aria-label={gettext("Add an item to %{field}", field: @definition.label)}
          class="field-input min-w-0 flex-1 border-dashed py-1 text-sm"
        />
      </div>
      <p class="mt-1 text-xs text-base-content/60">
        <span :if={@definition.help_text}>{@definition.help_text}</span>
        <span :if={!@full?}>
          {gettext("Press Enter to add. Paste several lines to add one item per line.")}
        </span>
        <span :if={@full?}>
          {gettext("At the limit of %{max} items.", max: @definition.max_items)}
        </span>
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  # A multiple select (several terms): the chosen terms as removable chips,
  # each carried by a hidden `name[]` input so the order on screen is the
  # order submitted, and a text box that adds one. The box suggests the
  # field's options plus — on an open vocabulary (`allow_custom`) — the terms
  # already in use on the type (`options`, from `KilnCMS.CMS.SelectTerms`),
  # less the ones already chosen. Enter, a comma or picking a suggestion adds
  # the term (the `TermPicker` hook); the chips' × and a drag by the handle
  # remove and reorder. All of it is server-side edits of the form params, as
  # a gallery's are, so the chips never hold state the form doesn't. A term
  # outside a fixed vocabulary is still added and then refused by the field's
  # validation, which says which term and why.
  #
  # The leading blank `name[]` input makes an emptied field submit at all (see
  # the gallery above); `ApplyCustomFields` drops it. The text box has no
  # `name`, so what is half-typed in it is never submitted.
  def custom_field_input(%{definition: %{field_type: :select, multiple: true}} = assigns) do
    terms = select_terms(assigns.value)

    assigns =
      assigns
      |> assign(:terms, terms)
      |> assign(:suggestions, Enum.reject(assigns.options, &(&1 in terms)))
      |> assign(:full?, full?(assigns.definition, length(terms)))

    ~H"""
    <div
      id={cf_id(@definition)}
      role="group"
      aria-labelledby={"#{cf_id(@definition)}-label"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{cf_id(@definition)}-label"} class="text-sm font-medium">
          {@definition.label}
        </span>
        <span :if={@terms != []} class="text-xs tabular-nums text-base-content/60">
          {ngettext("%{count} term", "%{count} terms", length(@terms))}
        </span>
      </div>
      <input type="hidden" name={"#{@name}[]"} value="" />
      <div class={[
        "field-input flex min-h-10 flex-wrap items-center gap-1.5 py-1.5 transition-shadow focus-within:ring-2 focus-within:ring-primary/30",
        @errors != [] && "border-error"
      ]}>
        <ul
          :if={@terms != []}
          id={"#{cf_id(@definition)}-terms"}
          phx-hook="Sortable"
          data-sort-event="list_item_reorder"
          data-sort-field={@definition.name}
          aria-label={gettext("Chosen terms")}
          class="contents"
        >
          <li
            :for={{term, index} <- Enum.with_index(@terms)}
            id={"cf-term-#{@definition.name}-#{index}"}
            data-sort-id={index}
            class="group inline-flex max-w-full items-center gap-0.5 rounded-full border border-primary/20 bg-primary/10 py-0.5 pl-1 pr-0.5 text-sm text-base-content transition-colors hover:border-primary/40"
          >
            <input type="hidden" name={"#{@name}[]"} value={term} />
            <span
              data-drag-handle
              title={gettext("Drag to reorder")}
              class="cursor-grab text-base-content/30 transition-colors group-hover:text-base-content/60 active:cursor-grabbing"
            >
              <.icon name="hero-bars-2" class="size-3" />
            </span>
            <span
              class="truncate px-0.5"
              title={if(FieldDefinition.option_label(@definition, term) != term, do: term)}
            >
              {FieldDefinition.option_label(@definition, term)}
            </span>
            <button
              type="button"
              phx-click="list_item_remove"
              phx-value-field={@definition.name}
              phx-value-index={index}
              aria-label={
                gettext("Remove %{term}", term: FieldDefinition.option_label(@definition, term))
              }
              class="rounded-full p-0.5 text-base-content/50 transition-colors hover:bg-error/15 hover:text-error focus-visible:bg-error/15 focus-visible:text-error"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </li>
        </ul>
        <input
          :if={!@full?}
          type="text"
          id={"#{cf_id(@definition)}-entry"}
          phx-hook="TermPicker"
          data-field={@definition.name}
          data-count={length(@terms)}
          list={"#{cf_id(@definition)}-suggestions"}
          autocomplete="off"
          enterkeyhint="enter"
          placeholder={
            if(@definition.allow_custom,
              do: gettext("Add a term…"),
              else: gettext("Choose a term…")
            )
          }
          aria-label={gettext("Add a term to %{field}", field: @definition.label)}
          class="min-w-32 flex-1 border-0 bg-transparent p-0.5 text-sm outline-none placeholder:text-base-content/40 focus:ring-0"
        />
        <datalist id={"#{cf_id(@definition)}-suggestions"}>
          <%!-- The label is what an editor types and reads; `list_item_add`
                maps it back to the stored value. --%>
          <option
            :for={suggestion <- @suggestions}
            value={FieldDefinition.option_label(@definition, suggestion)}
          />
        </datalist>
      </div>
      <p class="mt-1 text-xs text-base-content/60">
        <span :if={@definition.help_text}>{@definition.help_text}</span>
        <span :if={!@full?}>
          {if(@definition.allow_custom,
            do: gettext("Press Enter or comma to add. New terms are welcome."),
            else: gettext("Press Enter or comma to add one of the options.")
          )}
        </span>
        <span :if={@full?}>
          {gettext("At the limit of %{max} terms.", max: @definition.max_items)}
        </span>
      </p>
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
          {FieldDefinition.option_label(@definition, opt)}
        </option>
      </select>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  # A console account (#2044): one of the site's people, by id. The field is
  # always private, which the label says, so a writer knows the choice stays
  # in the console. An id that is no longer on the roster (someone who left
  # the site) is still shown, as itself, so saving without touching the
  # field is what tells the writer.
  def custom_field_input(%{definition: %{field_type: :user}} = assigns) do
    assigns =
      assign(
        assigns,
        :stray,
        is_binary(assigns.value) and assigns.value != "" and
          not Enum.any?(assigns.options, fn {_label, id} -> id == assigns.value end)
      )

    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 flex items-center gap-1.5 text-sm font-medium">
        {@definition.label}
        <span
          title={gettext("Only editors and admins see this")}
          class="inline-flex items-center gap-1 text-xs font-normal text-base-content/60"
        >
          <.icon name="hero-lock-closed" class="size-3" />{gettext("private")}
        </span>
      </label>
      <select
        id={cf_id(@definition)}
        name={@name}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && cf_errors_id(@definition)}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :if={@stray} value={@value} selected>{@value}</option>
        <option :for={{label, id} <- @options} value={id} selected={to_string(@value) == id}>
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

  # A rich `:text` field (the default `format`): the TipTap field editor over
  # a hidden input holding the HTML (`RichTextField` hook, `mountField` in
  # rich_text.js). The editor and its toolbar are the hook's, behind
  # `phx-update="ignore"`; the hidden input stays outside it, so a patch from
  # the server (a restore, a lock) still reaches it and the hook follows.
  #
  # A value that is JSON data (a list stored as text, awaiting
  # `mix kiln.fields.convert`) keeps the plain textarea — TipTap would wrap it
  # in a paragraph — as does a `:plain` field.
  def custom_field_input(%{definition: %{field_type: :text} = definition} = assigns)
      when not is_map_key(definition, :format) or definition.format == :rich do
    if KilnCMS.CMS.TextFormat.json_data?(assigns.value),
      do: plain_text_input(assigns),
      else: rich_text_input(assigns)
  end

  def custom_field_input(%{definition: %{field_type: :text}} = assigns),
    do: plain_text_input(assigns)

  # A `:group` field (structured rows): its sub-fields' own inputs, one set
  # for a single group and one per row for a repeating one. The wire shape —
  # rows keyed by position, the blank `_` / `_row` markers — is
  # `KilnCMSWeb.ContentEditor.GroupRows`'s, which folds it back into the list
  # `ApplyCustomFields` coerces. Add, remove and move are server-side edits of
  # the form params (`group_row_*`), as a gallery's are, so the rows never
  # hold state the form doesn't; dragging a row by its handle sends the same
  # reorder through the shared `Sortable` hook.
  #
  # `value` must be what was posted while the form holds it — not the cleaned
  # value, which drops a blank row the moment it is added.
  def custom_field_input(%{definition: %{field_type: :group}} = assigns) do
    definition = assigns.definition

    assigns =
      assigns
      |> assign(:subs, FieldDefinition.group_fields(definition))
      |> assign(:problems, GroupRows.errors(assigns.errors, definition.name))

    if definition.multiple,
      do: group_rows_input(assign(assigns, :rows, GroupRows.rows(assigns.value))),
      else: group_input(assign(assigns, :row, GroupRows.row(assigns.value)))
  end

  # Everything else is registry-driven. A composite field type
  # (`Kiln.FieldType` declaring `input_parts/1`, e.g. `:geolocation`) renders a
  # labelled input per part; anything else renders a single `<input>`.
  #
  # A type declaring `input_hook/1` (#1918) gets its widget wrapped in the
  # hook's element, so the hook sees every part of a composite field.
  def custom_field_input(assigns) do
    case field_type_hook(assigns.definition) do
      nil ->
        bare_custom_field_input(assigns)

      %{} = hook ->
        assigns = assign(assigns, :hook, hook)

        ~H"""
        <div
          id={cf_hook_id(@definition)}
          phx-hook={@hook.hook}
          data-field={@definition.name}
          data-config={@hook.config}
        >
          {bare_custom_field_input(assigns)}
        </div>
        """
    end
  end

  defp rich_text_input(assigns) do
    ~H"""
    <div
      id={"cf-rich-#{@definition.name}"}
      phx-hook="RichTextField"
      data-label-id={"#{cf_id(@definition)}-label"}
      aria-describedby={@errors != [] && cf_errors_id(@definition)}
    >
      <span id={"#{cf_id(@definition)}-label"} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </span>
      <input type="hidden" id={cf_id(@definition)} name={@name} value={@value} data-field-value />
      <div
        id={"cf-rich-#{@definition.name}-editor"}
        phx-update="ignore"
        class={["rt-field", @errors != [] && "rt-field-invalid"]}
      >
        <div
          data-toolbar
          role="toolbar"
          aria-label={gettext("Formatting for %{field}", field: @definition.label)}
          class="rt-field-toolbar"
        >
        </div>
        <div data-field-editor></div>
      </div>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@errors} />
    </div>
    """
  end

  defp plain_text_input(assigns) do
    ~H"""
    <div>
      <label for={cf_id(@definition)} class="mb-1 block text-sm font-medium">
        {@definition.label}
      </label>
      <textarea
        id={cf_id(@definition)}
        name={@name}
        placeholder={@placeholder}
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

  # A single group: one fieldset of its sub-fields' inputs.
  defp group_input(assigns) do
    ~H"""
    <fieldset
      id={cf_id(@definition)}
      aria-describedby={@problems.field != [] && cf_errors_id(@definition)}
    >
      <legend class="mb-1 block text-sm font-medium">{@definition.label}</legend>
      <%= if @subs == [] do %>
        <.group_empty_note />
      <% else %>
        <input type="hidden" name={"#{@name}[_]"} value="" />
        <div class="grid gap-3 rounded-lg border border-base-content/10 bg-base-200/30 p-3 sm:grid-cols-2">
          <.group_cell
            :for={sub <- @subs}
            group={@definition}
            sub={sub}
            index={nil}
            name={"#{@name}[#{sub.name}]"}
            value={Map.get(@row, sub.name)}
            errors={Map.get(@problems.cells, {nil, sub.name}, [])}
          />
        </div>
      <% end %>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@problems.field} />
    </fieldset>
    """
  end

  # A repeating group: an ordered list of rows, each with a drag handle, move
  # buttons and a remove button, then "Add row". `min_items`/`max_items` only
  # disable the buttons here; the save is what enforces them.
  defp group_rows_input(assigns) do
    assigns =
      assigns
      |> assign(:last, length(assigns.rows) - 1)
      |> assign(:full?, GroupRows.full?(assigns.rows, assigns.definition))
      |> assign(:at_minimum?, GroupRows.at_minimum?(assigns.rows, assigns.definition))

    ~H"""
    <div
      id={cf_id(@definition)}
      role="group"
      aria-labelledby={"#{cf_id(@definition)}-label"}
      aria-describedby={@problems.field != [] && cf_errors_id(@definition)}
    >
      <div class="mb-1 flex items-baseline justify-between gap-2">
        <span id={"#{cf_id(@definition)}-label"} class="text-sm font-medium">
          {@definition.label}
        </span>
        <span :if={@rows != []} class="text-xs text-base-content/60">
          {rows_count(@rows, @definition)}
        </span>
      </div>
      <%= if @subs == [] do %>
        <.group_empty_note />
      <% else %>
        <input type="hidden" name={"#{@name}[_]"} value="" />
        <ol
          :if={@rows != []}
          id={"#{cf_id(@definition)}-rows"}
          phx-hook="Sortable"
          data-sort-event="group_row_reorder"
          data-sort-field={@definition.name}
          class="space-y-2"
        >
          <li
            :for={{row, index} <- Enum.with_index(@rows)}
            id={"cf-group-#{@definition.name}-row-#{index}"}
            data-sort-id={index}
            class={[
              "rounded-lg border bg-base-200/30 p-3 transition-colors",
              if(group_row_errors?(@problems, index),
                do: "border-error/50",
                else: "border-base-content/10 hover:border-base-content/20"
              )
            ]}
          >
            <input type="hidden" name={"#{@name}[#{index}][_row]"} value="" />
            <div class="mb-2 flex items-center justify-between gap-2">
              <div class="flex min-w-0 items-center gap-1">
                <button
                  type="button"
                  data-drag-handle
                  aria-label={gettext("Drag to reorder row %{position}", position: index + 1)}
                  title={gettext("Drag to reorder")}
                  class="-ml-1 cursor-grab rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content active:cursor-grabbing"
                >
                  <.icon name="hero-bars-2" class="size-4" />
                </button>
                <span class="text-xs font-medium tabular-nums text-base-content/70">
                  {gettext("Row %{position}", position: index + 1)}
                </span>
              </div>
              <div class="flex shrink-0 items-center gap-0.5">
                <button
                  type="button"
                  phx-click="group_row_move"
                  phx-value-field={@definition.name}
                  phx-value-index={index}
                  phx-value-dir="up"
                  disabled={index == 0}
                  aria-label={gettext("Move row %{position} up", position: index + 1)}
                  class="btn btn-sm btn-ghost px-1.5"
                >
                  <.icon name="hero-chevron-up" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="group_row_move"
                  phx-value-field={@definition.name}
                  phx-value-index={index}
                  phx-value-dir="down"
                  disabled={index == @last}
                  aria-label={gettext("Move row %{position} down", position: index + 1)}
                  class="btn btn-sm btn-ghost px-1.5"
                >
                  <.icon name="hero-chevron-down" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="group_row_remove"
                  phx-value-field={@definition.name}
                  phx-value-index={index}
                  disabled={@at_minimum?}
                  aria-label={gettext("Remove row %{position}", position: index + 1)}
                  title={
                    @at_minimum? &&
                      ngettext(
                        "This field needs at least one row.",
                        "This field needs at least %{count} rows.",
                        @definition.min_items
                      )
                  }
                  class="rounded px-1.5 py-1 text-base-content/60 transition-colors hover:bg-base-200 hover:text-error disabled:pointer-events-none disabled:opacity-40"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </div>
            <div class="grid gap-3 sm:grid-cols-2">
              <.group_cell
                :for={sub <- @subs}
                group={@definition}
                sub={sub}
                index={index}
                name={"#{@name}[#{index}][#{sub.name}]"}
                value={Map.get(row, sub.name)}
                errors={Map.get(@problems.cells, {index, sub.name}, [])}
              />
            </div>
            <p
              :for={message <- Map.get(@problems.rows, index, [])}
              class="mt-2 flex items-center gap-1 text-xs text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-4" /> {message}
            </p>
          </li>
        </ol>
        <p :if={@rows == []} class="text-sm text-base-content/60">
          {gettext("No rows yet.")}
        </p>
        <button
          type="button"
          id={"#{cf_id(@definition)}-add"}
          phx-click="group_row_add"
          phx-value-field={@definition.name}
          disabled={@full?}
          class="btn btn-sm btn-default mt-2"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add row")}
        </button>
        <p :if={@full?} class="mt-1 text-xs text-base-content/60">
          {ngettext(
            "That's the most this field holds — one row.",
            "That's the most this field holds — %{count} rows.",
            @definition.max_items
          )}
        </p>
      <% end %>
      <p :if={@definition.help_text} class="mt-1 text-xs text-base-content/60">
        {@definition.help_text}
      </p>
      <.custom_field_errors_list definition={@definition} errors={@problems.field} />
    </div>
    """
  end

  defp group_empty_note(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">
      {gettext("This group has no fields yet. An admin adds them under Custom fields.")}
    </p>
    """
  end

  attr :group, :map, required: true
  attr :sub, :map, required: true
  attr :index, :any, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :errors, :list, required: true

  # One sub-field of one row, through the same inputs a top-level field gets,
  # under an id of its own (`custom-field-<group>-<row>-<sub>`). The browser's
  # `required` is left off: a blank row is dropped on save, so it must never
  # block one, and the save names a missing value next to its input.
  #
  # A checkbox posts nothing when cleared — no hidden `"false"` — because a
  # posted `"false"` is not blank, and would turn every untouched row into a
  # filled-in one that its other required sub-fields then refuse.
  defp group_cell(%{sub: %{field_type: :boolean}} = assigns) do
    assigns = assign(assigns, :id, group_cell_id(assigns.group, assigns.index, assigns.sub))

    ~H"""
    <div class="self-end">
      <label class="flex items-center gap-2 text-sm">
        <input
          id={@id}
          type="checkbox"
          name={@name}
          value="true"
          checked={@value in [true, "true", "1", "on"]}
          aria-invalid={@errors != [] && "true"}
          class="size-4 rounded border border-base-content/30 accent-primary"
        />
        <span class="font-medium">{@sub.label}</span>
      </label>
      <p :for={message <- @errors} class="mt-1 flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-4" /> {message}
      </p>
    </div>
    """
  end

  defp group_cell(assigns) do
    definition = %{
      assigns.sub
      | name: group_cell_key(assigns.group, assigns.index, assigns.sub),
        required: false,
        # Said once, on the first row, rather than on every one.
        help_text: if(assigns.index in [nil, 0], do: assigns.sub.help_text)
    }

    assigns = assign(assigns, :cell, definition)

    ~H"""
    <.custom_field_input definition={@cell} name={@name} value={@value} errors={@errors} />
    """
  end

  defp group_cell_key(group, nil, sub), do: "#{group.name}-#{sub.name}"
  defp group_cell_key(group, index, sub), do: "#{group.name}-#{index}-#{sub.name}"
  defp group_cell_id(group, index, sub), do: "custom-field-" <> group_cell_key(group, index, sub)

  defp group_row_errors?(problems, index) do
    Map.has_key?(problems.rows, index) or
      Enum.any?(problems.cells, fn {{row, _sub}, _messages} -> row == index end)
  end

  defp rows_count(rows, %{max_items: max}) when is_integer(max),
    do: gettext("%{count} of %{max} rows", count: length(rows), max: max)

  defp rows_count(rows, _definition),
    do: ngettext("%{count} row", "%{count} rows", length(rows))

  defp bare_custom_field_input(assigns) do
    case field_type_parts(assigns.definition) do
      [] -> scalar_custom_field_input(assigns)
      parts -> composite_custom_field_input(assign(assigns, :parts, parts))
    end
  end

  # `%{hook: name, config: json}` for a field type declaring a client hook, or
  # nil. Probed like `input_parts/1` (optional on the contract, and the module
  # may not be loaded yet). A raise or a malformed return renders the field
  # without its hook rather than taking the editor down: the plain inputs still
  # edit the value, only the convenience is lost.
  defp field_type_hook(definition) do
    with module when not is_nil(module) <- KilnCMS.CMS.FieldTypes.get(definition.field_type),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :input_hook, 1) do
      case module.input_hook(definition) do
        %{hook: hook} = spec when is_binary(hook) and hook != "" ->
          %{hook: hook, config: Jason.encode!(Map.get(spec, :data, %{}))}

        nil ->
          nil

        other ->
          Logger.warning(
            "#{inspect(module)}.input_hook/1 returned #{inspect(other)}; " <>
              "expected %{hook: name, data: map} or nil"
          )

          nil
      end
    else
      _no_hook -> nil
    end
  rescue
    exception ->
      Logger.warning(
        "input_hook/1 for field #{inspect(definition.name)} raised: " <>
          Exception.message(exception)
      )

      nil
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
        placeholder={@placeholder}
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

  # The items of a list field (a multiple select's terms, a multiple string's
  # phrases), from the stored list or the posted one (blank sentinel
  # included); a single string stored while the field was single is its one
  # item.
  defp select_terms(value) when is_list(value),
    do: value |> Enum.map(&to_string/1) |> Enum.reject(&(String.trim(&1) == ""))

  defp select_terms(value) when is_binary(value) and value != "", do: [value]
  defp select_terms(_value), do: []

  # A list of phrases as the form holds it: the posted list less its leading
  # blank sentinel, blank items kept (see the input above); a stored list
  # never holds a blank, and a stored single string is its one item.
  defp list_items(["" | items]), do: Enum.map(items, &to_string/1)
  defp list_items(items) when is_list(items), do: Enum.map(items, &to_string/1)
  defp list_items(value), do: select_terms(value)

  defp full?(%{max_items: max}, count) when is_integer(max), do: count >= max
  defp full?(_definition, _count), do: false

  defp cf_id(definition), do: "custom-field-#{definition.name}"
  # Its own prefix: `custom-field-<name>-<x>` is already the part-id space.
  defp cf_hook_id(definition), do: "cf-hook-#{definition.name}"
  defp cf_errors_id(definition), do: "custom-field-#{definition.name}-errors"
  defp cf_part_id(definition, part), do: "custom-field-#{definition.name}-#{part.key}"

  # One part of a composite value: the stored/mid-edit map's entry for that key.
  # The value may still be the raw param map during a validate round-trip, so
  # accept string keys only (jsonb and form params both give strings).
  defp composite_part_value(value, key) when is_map(value), do: Map.get(value, key)
  defp composite_part_value(_value, _key), do: nil

  # The current selection for a pick-list field: the stored snapshot's id, or
  # the raw id while a change is mid-validate.
  # A gallery's entries, whichever shape the value is in: the stored snapshots
  # (or the ones the last validate resolved), the raw ids a failed validate
  # left in the params, or a lone snapshot from before the field became a
  # gallery. A raw id borrows its url from the library window when it can.
  defp gallery_items(value, media) do
    by_id = Map.new(media, &{to_string(&1.id), &1})

    value
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id} = snapshot when is_binary(id) and id != "" ->
        [%{id: id, url: snapshot["url"], alt: snapshot["alt"]}]

      id when is_binary(id) and id != "" ->
        row = Map.get(by_id, id, %{})
        [%{id: id, url: Map.get(row, :url), alt: Map.get(row, :alt)}]

      _blank ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

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
              class="btn-link text-primary-ink hover:underline"
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
          class="field-input"
        />
        <textarea
          name="task_note"
          phx-change="task_draft_change"
          phx-debounce="blur"
          placeholder={gettext("Note (optional)")}
          class="field-input min-h-16"
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

  defp release_item_note(:unpublish, _live?),
    do: gettext("Will be unpublished when the release goes live.")

  defp release_item_note(_publish, true),
    do: gettext("Live now. Changes you save go live with the release.")

  defp release_item_note(_publish, _live?),
    do: gettext("Will be published when the release goes live.")

  attr :item, :map, default: nil
  attr :release, :map, default: nil
  attr :releases, :list, required: true
  attr :draft, :map, required: true
  # A live record's Save holds its changes for the release to publish (#1815).
  attr :live?, :boolean, default: false

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
            {release_item_note(@item.action, @live?)}
          </p>
          <button
            type="button"
            phx-click="release_remove"
            class="btn-link mt-2 text-primary-ink hover:underline"
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
  # A featured image the type shares across locales, on a translation (#1327,
  # #1860): shown, with no way to pick or remove one here.
  attr :locked, :boolean, default: false

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
          :if={not @locked}
          type="button"
          phx-click="open_featured_picker"
          class="btn btn-sm btn-default"
        >
          {gettext("Choose from library")}
        </button>
        <button
          :if={@selected && not @locked}
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
  #
  # The kit `.tabs` segmented control with the WAI-ARIA tabs pattern (#1679,
  # the same shape as the Form Builder's, #1680): each tab names the panel it
  # controls (all three stay mounted, so every `aria-controls` resolves), only
  # the selected tab sits in the Tab order, and the shared `TabKeys` hook
  # (assets/js/tab_keys.js) adds Left/Right/Home/End. The panels carry the
  # matching `role="tabpanel"` + `aria-labelledby` (`inspector_panel_attrs/1`).
  attr :tab, :atom, required: true
  attr :settings_alert, :boolean, default: false

  def inspector_tabs(assigns) do
    ~H"""
    <div
      id="inspector-tabs"
      role="tablist"
      aria-label={gettext("Inspector")}
      phx-hook="TabKeys"
      class="tabs flex w-full"
    >
      <button
        :for={
          {id, label, icon, alert} <- [
            {:preview, gettext("Preview"), "hero-eye", false},
            {:settings, gettext("Settings"), "hero-adjustments-horizontal", @settings_alert},
            {:history, gettext("History"), "hero-clock", false}
          ]
        }
        id={"inspector-tab-#{id}"}
        type="button"
        role="tab"
        class="tab flex-1 justify-center"
        aria-selected={to_string(@tab == id)}
        aria-controls={"inspector-panel-#{id}"}
        tabindex={if @tab == id, do: "0", else: "-1"}
        phx-click="switch_inspector_tab"
        phx-value-tab={id}
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

  @doc """
  The ARIA attributes of inspector panel `tab`, as rendered on the root of
  each inspector panel component: `role="tabpanel"`, the `id` its tab's
  `aria-controls` names, `aria-labelledby` back to that tab, and
  `tabindex="0"` so the panel itself is reachable by Tab.
  """
  def inspector_panel_attrs(tab) when tab in [:preview, :settings, :history] do
    [
      id: "inspector-panel-#{tab}",
      role: "tabpanel",
      "aria-labelledby": "inspector-tab-#{tab}",
      # A panel whose first content is not focusable (an empty preview, a
      # one-version history) is still a Tab stop after its tab (APG tabs).
      tabindex: "0"
    ]
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
  # The jump is faded out, not `hidden` (#1679): a `display: none` link is out
  # of the Tab order, so the hover-only version was unreachable by keyboard.
  # Now that every block's jump is a Tab stop, each is named by the block's
  # position — a list of identical "Edit" links says nothing about where
  # each one goes.
  attr :form, :any, required: true
  attr :html, :any, required: true
  attr :kind, :atom, required: true
  attr :slug, :string, required: true

  def preview_article(assigns) do
    ~H"""
    <article class="prose max-w-none space-y-3 rounded border border-base-content/15 p-5">
      <h2 class="text-2xl font-bold">{@form[:title].value}</h2>
      <div
        :for={{{id, html}, i} <- Enum.with_index(@html, 1)}
        class="group relative -mx-2 rounded px-2 transition hover:bg-base-200/40"
      >
        <div class="kiln-block">{html}</div>
        <.link
          :if={id}
          navigate={~p"/editor/site/#{@kind}/#{@slug}?#{[focus: id]}"}
          class="absolute right-1 top-1 z-10 inline-flex items-center gap-1 rounded bg-base-100/95 px-1.5 py-0.5 text-xs font-medium text-base-content no-underline opacity-0 shadow ring-1 ring-base-content/10 transition-opacity group-hover:opacity-100 focus-visible:opacity-100 focus-visible:outline-2 focus-visible:outline-primary pointer-coarse:opacity-100"
          title={gettext("Edit this block on the page")}
          aria-label={gettext("Edit block %{n} on the page", n: i)}
        >
          <.icon name="hero-pencil-square" class="size-3" />{gettext("Edit")}
        </.link>
      </div>
    </article>
    """
  end
end
