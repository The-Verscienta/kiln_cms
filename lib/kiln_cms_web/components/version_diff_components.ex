defmodule KilnCMSWeb.VersionDiffComponents do
  @moduledoc """
  Renders a `KilnCMS.CMS.VersionDiff` — the editor's side-by-side version
  comparison (#467).

  The diff itself is computed in the CMS layer; everything here is presentation:
  the modal shell, the human labels for attribute names and block types, and the
  markup for a word-level run.

  Changed prose renders as real `<del>`/`<ins>` elements rather than coloured
  spans. Colour alone doesn't survive a screen reader or a monochrome display,
  and "what changed" is the entire content of this view. For the same reason the
  tints carry `*-ink` rather than the raw accent: an accent used as text on its
  own pale tint only reaches ~2-4:1 (see the ink-token note in `assets/css/app.css`).
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [icon: 1]

  alias KilnCMS.CMS.VersionDiff

  @doc """
  The compare modal.

  `left` and `right` are the two sides being compared, each
  `%{label: String.t(), version_id: String.t() | nil}` — a `nil` `version_id`
  means the unsaved working draft, which has nothing to restore to.
  """
  attr :diff, VersionDiff, required: true
  attr :left, :map, required: true
  attr :right, :map, required: true

  def version_compare(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50" phx-window-keydown="close_compare" phx-key="Escape">
      <div class="absolute inset-0 bg-black/40" phx-click="close_compare" aria-hidden="true"></div>
      <div
        id="version-compare-dialog"
        phx-hook="FocusTrap"
        role="dialog"
        aria-modal="true"
        aria-labelledby="version-compare-title"
        tabindex="-1"
        class="absolute inset-4 mx-auto flex max-w-4xl flex-col overflow-hidden rounded-lg border border-base-content/10 bg-base-100 shadow-xl"
      >
        <div class="flex items-start justify-between gap-4 border-b border-base-content/10 p-4">
          <div class="min-w-0">
            <h2 id="version-compare-title" class="text-lg font-medium">
              {gettext("Compare versions")}
            </h2>
            <div class="mt-1 flex flex-wrap items-center gap-2 text-sm text-base-content/70">
              <.side_label side={@left} />
              <.icon name="hero-arrow-right" class="size-4 shrink-0" />
              <.side_label side={@right} />
            </div>
          </div>
          <button
            type="button"
            phx-click="close_compare"
            aria-label={gettext("Close")}
            class="rounded p-1 text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4">
          <p :if={!@diff.changed?} class="text-sm text-base-content/60">
            {gettext("These two versions are identical.")}
          </p>

          <section :if={@diff.fields != []} class="mb-6">
            <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
              {gettext("Fields")}
            </h3>
            <ul class="space-y-3">
              <li :for={field <- @diff.fields} class="rounded border border-base-content/10 p-3">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-sm font-medium">{field_label(field.name)}</span>
                  <.status_pill status={field.status} />
                  <%!-- Restore sits a few inches away in this same modal, and it
                        moves editorial content only — workflow and attribution
                        are left as they are. Saying so here is the difference
                        between a documented rule and a silent no-op (#691). The
                        rationale is a visible line rather than a `title=`
                        tooltip: `/editor` ships as an installable PWA (#65),
                        and a phone has no hover. --%>
                  <.pill :if={!field.restorable?} tone="bg-base-200 text-base-content/60">
                    {gettext("Not restored")}
                  </.pill>
                </div>
                <p :if={!field.restorable?} class="mt-1 text-xs text-base-content/60">
                  {gettext(
                    "Restoring a version reverts editorial content. Workflow state, schedule and author stay as they are."
                  )}
                </p>
                <.field_body field={field} />
              </li>
            </ul>
          </section>

          <%!-- Gated on `changed?`, not on the block list: an identical pair still
                carries every block as `:unchanged`, and printing "No changes"
                forty times under a banner saying the versions are identical is
                noise, not context. --%>
          <section :if={@diff.changed? && @diff.blocks != []}>
            <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
              {gettext("Content blocks")}
            </h3>
            <ol class="space-y-2">
              <li
                :for={block <- @diff.blocks}
                class={[
                  "rounded border p-3",
                  block_border(block)
                ]}
              >
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-sm font-medium">{block_label(block.type)}</span>
                  <.status_pill status={block.status} />
                  <.pill :if={block.moved?} tone="bg-info/20 text-info-ink">
                    {gettext("Moved %{from} → %{to}",
                      from: block.old_index + 1,
                      to: block.new_index + 1
                    )}
                  </.pill>
                </div>

                <p
                  :if={block.status == :unchanged && !block.moved?}
                  class="mt-1 text-xs text-base-content/50"
                >
                  {gettext("No changes")}
                </p>

                <p :if={block.inline} class="mt-2 text-sm leading-relaxed">
                  <.runs runs={block.inline} />
                </p>

                <%!-- Rendered alongside the prose runs, not instead of them. A
                      block whose text is untouched but whose `level`, `citation`
                      or `alt` changed produces an all-`:eq` inline diff, and
                      gating this on `inline == nil` hid the only thing that
                      actually changed. `VersionDiff` drops the prose fields from
                      `fields` when it emitted runs for them. --%>
                <dl :if={block.fields != []} class="mt-2 space-y-1 text-sm">
                  <div :for={change <- block.fields} class="flex flex-wrap items-baseline gap-2">
                    <dt class="text-xs uppercase tracking-wide text-base-content/50">
                      {change.name}
                    </dt>
                    <dd class="flex flex-wrap items-baseline gap-2">
                      <.value_pair old={change.old} new={change.new} />
                    </dd>
                  </div>
                </dl>
              </li>
            </ol>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :side, :map, required: true

  defp side_label(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <span class="truncate rounded bg-base-200 px-2 py-0.5 text-xs">{@side.label}</span>
      <button
        :if={@side.version_id}
        type="button"
        phx-click="restore"
        phx-value-version_id={@side.version_id}
        data-confirm={gettext("Restore content to this version?")}
        class="text-xs text-primary hover:underline"
      >
        {gettext("Restore")}
      </button>
    </span>
    """
  end

  attr :field, :map, required: true

  defp field_body(assigns) do
    ~H"""
    <p :if={@field.inline} class="mt-1 text-sm leading-relaxed">
      <.runs runs={@field.inline} />
    </p>

    <dl :if={@field.entries != []} class="mt-1 space-y-1 text-sm">
      <div :for={entry <- @field.entries} class="flex flex-wrap items-baseline gap-2">
        <dt class="text-xs uppercase tracking-wide text-base-content/50">{entry.key}</dt>
        <dd class="flex flex-wrap items-baseline gap-2">
          <.value_pair old={entry.old} new={entry.new} />
        </dd>
      </div>
    </dl>

    <p :if={is_nil(@field.inline) && @field.entries == []} class="mt-1 text-sm">
      <.value_pair old={@field.old} new={@field.new} />
    </p>
    """
  end

  attr :old, :any, required: true
  attr :new, :any, required: true

  defp value_pair(assigns) do
    ~H"""
    <del :if={present?(@old)} class="rounded bg-error/20 px-1 text-error-ink">{format(@old)}</del>
    <.icon :if={present?(@old) && present?(@new)} name="hero-arrow-right" class="size-3 shrink-0" />
    <ins :if={present?(@new)} class="rounded bg-success/20 px-1 text-success-ink no-underline">
      {format(@new)}
    </ins>
    <span :if={!present?(@old) && !present?(@new)} class="text-base-content/50">—</span>
    """
  end

  # Runs are rendered inline, relying on HTML's normal whitespace collapsing.
  # The tokenizer keeps each run's own separators, so the joined runs already
  # read as the original prose — and `whitespace-pre-wrap` would additionally
  # preserve the template's newlines *between* runs, breaking a sentence onto one
  # line per changed word.
  attr :runs, :list, required: true

  defp runs(assigns) do
    ~H"""
    <%= for {op, text} <- @runs do %>
      <del :if={op == :del} class="bg-error/20 text-error-ink">{text}</del>
      <ins :if={op == :ins} class="bg-success/20 text-success-ink no-underline">{text}</ins>
      <span :if={op == :eq}>{text}</span>
    <% end %>
    """
  end

  # The one pill shape in this view. Three call sites render side by side in the
  # same flex row, so a padding or radius tweak on one of them is immediately
  # visible against the other two.
  attr :tone, :string, required: true
  slot :inner_block, required: true

  defp pill(assigns) do
    ~H"""
    <span class={["rounded px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide", @tone]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    ~H"""
    <.pill tone={status_class(@status)}>{status_label(@status)}</.pill>
    """
  end

  defp status_class(:added), do: "bg-success/20 text-success-ink"
  defp status_class(:removed), do: "bg-error/20 text-error-ink"
  defp status_class(:changed), do: "bg-warning/20 text-warning-ink"
  defp status_class(_unchanged), do: "bg-base-200 text-base-content/60"

  defp status_label(:added), do: gettext("Added")
  defp status_label(:removed), do: gettext("Removed")
  defp status_label(:changed), do: gettext("Changed")
  defp status_label(_unchanged), do: gettext("Unchanged")

  defp block_border(%{status: :added}), do: "border-success/40"
  defp block_border(%{status: :removed}), do: "border-error/40"
  defp block_border(%{status: :changed}), do: "border-warning/40"
  defp block_border(%{moved?: true}), do: "border-info/40"
  defp block_border(_block), do: "border-base-content/10"

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value) when is_list(value), do: value != []
  defp present?(_value), do: true

  # Values are truncated, and structures rendered as compact JSON rather than
  # `inspect/1`. A rich-text body or a nested column tree is thousands of
  # characters of Elixir map syntax; dumped whole it is unreadable, and it is the
  # editor's own content being echoed back into the page.
  @value_limit 200

  defp format(value) when is_binary(value), do: truncate(value)
  defp format(value) when is_number(value), do: to_string(value)
  defp format(value) when is_boolean(value), do: to_string(value)

  defp format(value) do
    truncate(Jason.encode!(value))
  rescue
    _error -> truncate(inspect(value))
  end

  defp truncate(text) when byte_size(text) <= @value_limit, do: text
  defp truncate(text), do: String.slice(text, 0, @value_limit) <> "…"

  # The labels, keyed rather than ordered (#712). Display order is
  # `KilnCMS.CMS.VersionFields.field_order/0`'s business and is not restated
  # here: the same nineteen names in the same order used to live in both places,
  # independently ordered, so an attribute added to one and not the other sorted
  # into the alphabetical "rest" bucket instead of where its author meant it.
  @labels %{
    title: "Title",
    slug: "Slug",
    path_alias: "Path alias",
    excerpt: "Excerpt",
    state: "State",
    audience: "Audience",
    locale: "Locale",
    seo_title: "SEO title",
    seo_description: "SEO description",
    seo_keywords: "SEO keywords",
    seo_image: "SEO image",
    canonical_url: "Canonical URL",
    published_at: "Published at",
    scheduled_at: "Scheduled at",
    unpublish_at: "Unpublish at",
    author_id: "Author",
    category_id: "Category",
    featured_image_id: "Featured image",
    custom_fields: "Custom fields"
  }

  @field_order KilnCMS.CMS.VersionFields.field_order()

  # A compile-time gate, in both directions. Reading `field_order/0` here makes
  # this module recompile whenever that list moves, so neither drift survives a
  # build:
  #
  #   * an ordered name with no label would fall through to
  #     `Phoenix.Naming.humanize/1` — untranslated, with nothing going red
  #   * a label for a name nobody orders is a dead clause that stays forever
  #
  # `content_editor_compare_test.exs` still gates the wider question this cannot
  # see: an attribute a *resource* declares that reached neither list.
  @unlabelled Enum.reject(@field_order, &Map.has_key?(@labels, &1))
  @unordered @labels |> Map.keys() |> Enum.reject(&(&1 in @field_order))

  if @unlabelled != [] or @unordered != [] do
    raise """
    KilnCMSWeb.VersionDiffComponents labels and \
    KilnCMS.CMS.VersionFields.field_order/0 have drifted.

      no label, would render untranslated: #{inspect(@unlabelled)}
      labelled but never ordered (dead):   #{inspect(@unordered)}
    """
  end

  @field_labels Enum.map(@field_order, &{&1, Map.fetch!(@labels, &1)})

  @doc """
  The attributes `field_label/1` has an explicit translated label for.

  In `KilnCMS.CMS.VersionFields.field_order/0` order, and equal to it as a set —
  see the compile-time gate above.
  """
  @spec labelled_fields() :: [atom()]
  def labelled_fields, do: Keyword.keys(@field_labels)

  @doc """
  Human label for a diffed attribute.

  Falls back to the humanized attribute name, which is untranslated — see
  `labelled_fields/0`.
  """
  @spec field_label(atom()) :: String.t()
  for {field, label} <- @field_labels do
    # `gettext/1` extracts at compile time, so the msgid has to reach it as a
    # literal — which it does, because `unquote/1` substitutes before expansion.
    def field_label(unquote(field)), do: gettext(unquote(label))
  end

  def field_label(name), do: name |> to_string() |> Phoenix.Naming.humanize()

  defp block_label(nil), do: gettext("Block")
  defp block_label(type), do: type |> to_string() |> Phoenix.Naming.humanize()
end
