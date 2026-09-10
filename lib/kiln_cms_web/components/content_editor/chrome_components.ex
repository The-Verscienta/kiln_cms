defmodule KilnCMSWeb.ContentEditor.ChromeComponents do
  @moduledoc """
  The content editor's sticky action-bar chrome (Theme A, #1311): state and
  freshness pills, schedule chips, the presence roster, word count and the
  accessibility chip, the autosave indicator and the workflow buttons. Moved
  verbatim from `KilnCMSWeb.ContentEditorLive`; events stay untargeted, so
  they keep landing on the enclosing LiveView.
  """

  use KilnCMSWeb, :html

  import KilnCMSWeb.ContentEditor.Shared, only: [color_for: 1, initials: 1]

  # Sticky editor action bar (Theme A). Sits just under the console shell header
  # (`sticky top-14`, below the shell's `top-0` z-20 bar) so Save, workflow, and
  # the live save state are always reachable no matter how long the content runs.
  # The `EditorActionBar` hook publishes the bar's stuck bottom edge as a CSS
  # variable so each rich-text block's formatting toolbar (`.rt-block-toolbar`)
  # can stick just beneath it while a long block scrolls past.
  attr :kind, :atom, required: true
  attr :record, :any, required: true
  attr :save_state, :atom, required: true
  attr :tier, :atom, required: true
  attr :conflict, :boolean, required: true
  attr :editors, :list, required: true
  attr :actor, :any, required: true
  attr :word_count, :integer, required: true
  attr :a11y_report, :map, required: true

  def editor_action_bar(assigns) do
    # Resolved once per render rather than per interpolation: `words_per_minute/0`
    # WARNS on a misconfigured value, so reading it three times turned one bad
    # config line into three log lines per keystroke.
    wpm = KilnCMS.CMS.Calculations.ReadingTime.words_per_minute()

    assigns =
      assigns
      |> assign(:wpm, wpm)
      |> assign(:reading_minutes, reading_minutes(assigns.word_count, wpm))

    ~H"""
    <div
      id="editor-action-bar"
      phx-hook="EditorActionBar"
      class="sticky top-14 z-10 rounded-lg border border-base-content/10 bg-base-100/90 px-3 py-2.5 shadow-sm backdrop-blur"
    >
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <span class={[
            "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium",
            state_badge_class(@record.state)
          ]}>
            <span class="size-1.5 rounded-full bg-current opacity-70"></span>
            {state_label(@record.state)}
          </span>
          <%!-- The freshness axis, next to the workflow one because they are
                orthogonal and an editor needs both at a glance: this document
                is Published *and* eight months past its review
                (docs/content-lifecycles.md). Renders nothing when fresh, which
                is nearly always. --%>
          <.health_badge health={@record.health} due_at={@record.due_at} />
          <%!-- Only when the health is actually asking. The attestation is a
                deliberate act, so it gets a button of its own rather than
                riding on Save — an editor who saves a typo fix has not
                re-read the piece. --%>
          <.button
            :if={@record.health in [:due, :overdue, :expired]}
            type="button"
            phx-click="mark_reviewed"
            size="sm"
          >
            {gettext("Mark reviewed")}
          </.button>
          <%!-- After saving a schedule, nothing else says it exists (U-M4). --%>
          <span
            :if={@record.scheduled_at && @record.state in [:draft, :in_review]}
            class="inline-flex items-center gap-1 text-xs text-base-content/60"
          >
            <.icon name="hero-clock" class="size-3.5" />
            {gettext("Publishes")}
            <time
              id="scheduled-publish-badge"
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(@record.scheduled_at)}
            >{Calendar.strftime(@record.scheduled_at, "%b %-d, %H:%M")} UTC</time>
          </span>
          <span
            :if={@record.unpublish_at && @record.state == :published}
            class="inline-flex items-center gap-1 text-xs text-base-content/60"
          >
            <.icon name="hero-clock" class="size-3.5" />
            {gettext("Unpublishes")}
            <time
              id="scheduled-unpublish-badge"
              phx-hook="LocalTime"
              datetime={DateTime.to_iso8601(@record.unpublish_at)}
            >{Calendar.strftime(@record.unpublish_at, "%b %-d, %H:%M")} UTC</time>
          </span>
          <.presence_roster editors={@editors} current_id={@actor.id} />

          <%!-- Word count and reading time (#492). Free to render: the count
                comes from `@seo_body_stats`, which the advisory panel already
                folds from the block tree and memoizes on a `phash2` digest, so
                this adds no per-keystroke walk of its own. --%>
          <span
            :if={@word_count > 0}
            class="inline-flex items-center gap-1 text-xs text-base-content/60"
            title={gettext("Reading time is an estimate at %{wpm} words per minute.", wpm: @wpm)}
          >
            <.icon name="hero-clock" class="size-3.5" />
            {ngettext("%{count} word", "%{count} words", @word_count, count: @word_count)} &middot; {ngettext(
              "%{count} min read",
              "%{count} min read",
              @reading_minutes,
              count: @reading_minutes
            )}
          </span>

          <%!-- Accessibility summary (#495). Up here rather than only in the
                inspector rail because a panel three sections down is one an
                author has to already care about to find — and the people this
                helps are the ones who don't yet know there's a problem.
                Free to render: the report is computed for the panel anyway.

                A button, not a badge: it opens the Settings tab, where the
                Accessibility section lives — the "expandable to the panel"
                half of the ask. It reuses the tab strip's own event rather
                than introducing a scroll hook, so there is one code path that
                changes which panel is showing.

                Hidden on a brand-new page: greeting an author with a verdict
                on an empty draft is noise. NOT gated on `total`, which is a
                trap — a check that passes counts as *applicable*, so an empty
                document reports one passing check and the chip would render
                "Accessible" on a page with nothing in it. Content, or a
                finding to show, is the honest signal. --%>
          <button
            :if={@a11y_report.findings != [] or @word_count > 0}
            id="a11y-chip"
            type="button"
            phx-click="switch_inspector_tab"
            phx-value-tab="settings"
            class={[
              "inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs font-medium",
              a11y_chip_class(@a11y_report.grade)
            ]}
            title={a11y_chip_title(@a11y_report)}
          >
            <.icon name={a11y_chip_icon(@a11y_report.grade)} class="size-3.5" />
            {a11y_chip_label(@a11y_report)}
          </button>
        </div>

        <div class="ml-auto flex flex-wrap items-center gap-2">
          <.autosave_status
            :if={@record.state == :draft or @save_state != :saved}
            state={@save_state}
          />
          <.workflow_buttons state={@record.state} tier={@tier} />
          <.button
            type="submit"
            variant="primary"
            disabled={@conflict}
            phx-disable-with={gettext("Saving…")}
            title={@conflict && gettext("Reload to resolve the edit conflict before saving.")}
          >
            {gettext("Save")}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  # Same arithmetic as `KilnCMS.CMS.Calculations.ReadingTime`, applied to the
  # in-progress draft rather than the saved record — so the editor's number and
  # the one consumers read off the API agree once the draft is saved.
  # Traffic-light vocabulary, shared with the grade pill in the panel
  # (`KilnCMSWeb.AdvisoryComponents`) so the chip and the section it scrolls to
  # can never disagree about what colour this document is.
  defp a11y_chip_class(:good), do: "bg-success/15 text-success hover:bg-success/25"
  defp a11y_chip_class(:ok), do: "bg-warning/20 text-warning-content hover:bg-warning/30"
  defp a11y_chip_class(:poor), do: "bg-error/12 text-error hover:bg-error/20"

  defp a11y_chip_icon(:good), do: "hero-check-circle"
  defp a11y_chip_icon(_grade), do: "hero-exclamation-circle"

  # The count, not the grade word: "2 issues" is the actionable number, and
  # the colour already carries the severity.
  defp a11y_chip_label(%{findings: []}), do: gettext("Accessible")

  defp a11y_chip_label(%{findings: findings}) do
    ngettext("%{count} a11y issue", "%{count} a11y issues", length(findings),
      count: length(findings)
    )
  end

  defp a11y_chip_title(%{findings: []}),
    do: gettext("No accessibility issues found. Opens the Accessibility panel.")

  defp a11y_chip_title(_report),
    do: gettext("Opens the Accessibility panel.")

  defp reading_minutes(0, _wpm), do: 0
  defp reading_minutes(words, wpm), do: ceil(words / wpm)

  # Pill color for a content state in the action bar. Uses the `*-ink` tokens
  # for the same reason CoreComponents.badge/1 does: the bare accent on its own
  # pale tint only reaches ~2-4:1 in light mode.
  defp state_badge_class(:published), do: "bg-success/15 text-success-ink"
  defp state_badge_class(:in_review), do: "bg-warning/15 text-warning-ink"
  # /70 rather than /60 to match badge/1's neutral tone — /60 lands at 3.8:1.
  defp state_badge_class(:archived), do: "bg-base-content/10 text-base-content/70"
  defp state_badge_class(_), do: "bg-info/15 text-info-ink"

  attr :editors, :list, required: true
  attr :current_id, :string, required: true

  # Live "who's editing" roster — overlapping colored avatar chips (one per
  # collaborator, in the same color as their cursor/lock badges) plus a count.
  # Hidden when you're the only one here. Self is sorted first and tagged
  # "(you)".
  def presence_roster(assigns) do
    others = Enum.reject(assigns.editors, &(&1.id == assigns.current_id))
    roster = Enum.sort_by(assigns.editors, &{&1.id != assigns.current_id, &1.name})

    assigns =
      assign(assigns, others: others, roster: roster, count: length(assigns.editors))

    ~H"""
    <div :if={@others != []} class="mt-2 flex items-center gap-2">
      <div class="flex">
        <span
          :for={e <- @roster}
          title={e.name <> if(e.id == @current_id, do: gettext(" (you)"), else: "")}
          class={[
            "-ml-1.5 flex size-6 items-center justify-center rounded-full text-[10px] font-semibold text-white ring-2 ring-base-100 first:ml-0",
            color_for(e.id)
          ]}
        >
          {initials(e.name)}
        </span>
      </div>
      <span class="text-xs text-base-content/60">{gettext("%{count} editing", count: @count)}</span>
    </div>
    """
  end

  attr :state, :atom, required: true

  # Draft autosave indicator shown next to the workflow/Save buttons. Covers the
  # in-flight (:saving) and validation-failure (:error) states too (#136).
  def autosave_status(assigns) do
    ~H"""
    <span
      class={["text-xs", (@state == :error && "text-error") || "text-base-content/70"]}
      aria-live="polite"
    >
      <%= case @state do %>
        <% :saving -> %>
          {gettext("Saving…")}
        <% :saved -> %>
          {gettext("Saved")}
        <% :synced -> %>
          <%!-- Collab: a co-editor persists; text edits are already in the
                shared doc. Fields outside the text still need Save. --%>
          {gettext("Synced live — co-editor saves")}
        <% :error -> %>
          {gettext("Couldn't autosave — check for errors")}
        <% _ -> %>
          {gettext("Unsaved changes")}
      <% end %>
    </span>
    """
  end

  attr :state, :atom, required: true
  attr :tier, :atom, required: true

  def workflow_buttons(assigns) do
    ~H"""
    <button
      :if={@state == :draft and @tier == :editor}
      type="button"
      phx-click="workflow"
      phx-value-action="submit"
      phx-disable-with={gettext("Submitting…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Submit for review")}
    </button>
    <button
      :if={@state in [:draft, :in_review] and @tier == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="publish"
      phx-disable-with={gettext("Publishing…")}
      class="btn btn-sm btn-default"
    >
      {if @state == :in_review, do: gettext("Approve & publish"), else: gettext("Publish")}
    </button>
    <button
      :if={@state == :in_review and @tier == :admin}
      type="button"
      phx-click="workflow"
      phx-value-action="return"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Request changes")}
    </button>
    <span
      :if={@state == :in_review and @tier == :editor}
      class="text-xs text-base-content/70"
    >
      {gettext("Awaiting admin approval")}
    </span>
    <button
      :if={@state == :published}
      type="button"
      phx-click="workflow"
      phx-value-action="unpublish"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Unpublish")}
    </button>
    <button
      :if={@state == :archived}
      type="button"
      phx-click="workflow"
      phx-value-action="unarchive"
      phx-disable-with={gettext("Working…")}
      class="btn btn-sm btn-default"
    >
      {gettext("Unarchive")}
    </button>
    """
  end
end
