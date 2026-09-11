defmodule KilnCMSWeb.ContentEditor.InspectorSettingsComponent do
  @moduledoc """
  The inspector rail's Settings panel (#1311): assignment, document notes,
  releases, organization & relationships, custom fields, accessibility,
  compliance, SEO & scheduling, internal links and similar content. Markup
  moved verbatim from `KilnCMSWeb.ContentEditorLive.render/1`.

  Two standing invariants ride along:

    * the panel stays mounted whichever tab is showing — visibility is CSS
      `hidden` keyed on `@inspector_tab`, never `:if` — so its form fields
      survive a submit while another tab is active;
    * nothing in here may introduce a `<form>`: this whole panel renders
      inside the page's own editor form, and the HTML parser silently drops a
      nested one. Inputs carry their own `phx-change` and buttons are plain
      `phx-click`, all untargeted so they land on the enclosing LiveView.
  """

  use KilnCMSWeb, :live_component

  import KilnCMSWeb.AccessibilityComponents, only: [a11y_findings: 1, a11y_grade_badge: 1]

  import KilnCMSWeb.ComplianceComponents,
    only: [compliance_findings: 1, compliance_grade_badge: 1]

  import KilnCMSWeb.SeoComponents, only: [seo_findings: 1, seo_grade_badge: 1]

  import KilnCMSWeb.ContentEditor.AdvisoryPanelComponents, only: [seo_suggestions: 1]
  import KilnCMSWeb.ContentEditor.InspectorComponents
  import KilnCMSWeb.ContentEditor.Shared

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["space-y-4", @inspector_tab != :settings && "hidden"]}>
      <.inspector_section title={gettext("Assignment")}>
        <.task_list
          tasks={@tasks}
          open?={@task_assign_open?}
          draft={@task_draft}
          assignable_users={@assignable_users}
          auto_complete_default={@auto_complete_default}
        />
      </.inspector_section>

      <.inspector_section title={gettext("Document notes")}>
        <.document_comment_panel comments={@comments} />
      </.inspector_section>

      <.inspector_section title={gettext("Release")}>
        <.release_panel
          item={@release_item}
          release={@release_of_item}
          releases={@releases}
          draft={@release_draft}
        />
      </.inspector_section>

      <.inspector_section title={gettext("Organization & relationships")}>
        <.input
          field={@form[:category_id]}
          type="select"
          label={gettext("Category")}
          prompt="— None —"
          options={Enum.map(@categories, &{&1.name, &1.id})}
        />

        <.input
          :if={length(@audiences) > 1}
          field={@form[:audience]}
          type="select"
          label={gettext("Audience")}
          options={@audiences}
        />

        <%!-- Shared-passphrase lock (#496). Plain inputs on the enclosing
                form, never a nested <form> — the settings rail's parser
                drops one silently.

                The current passphrase is never echoed back: only whether
                one is set. So a blank field means "leave it alone" and
                clearing needs the explicit checkbox, which is what
                `Changes.ApplyAccessPassword` reads. --%>
        <div class="space-y-2">
          <.input
            field={@form[:access_password]}
            type="password"
            value=""
            autocomplete="off"
            label={
              if content_locked?(@record),
                do: gettext("Replace passphrase"),
                else: gettext("Passphrase")
            }
            hint={
              gettext(
                "Anyone with this passphrase can read the published page. Weak protection, meant for convenience — use Audience for real access control."
              )
            }
          />
          <p :if={content_locked?(@record)} class="text-xs text-base-content/60">
            {gettext("A passphrase is set. Leave blank to keep it.")}
          </p>
          <.input
            :if={content_locked?(@record)}
            field={@form[:remove_access_password]}
            type="checkbox"
            label={gettext("Remove the passphrase")}
          />
        </div>

        <.tag_picker
          form={@form}
          tag_index={@tag_index}
          record={@record}
          open_sections={@tag_sections_open}
          tag_query={@tag_query}
          tags_capped?={length(@tags) >= @max_tags}
          tag_limit={@max_tags}
        />

        <.featured_image_field form={@form} media={@media} />

        <.input
          field={@form[@related_field]}
          type="select"
          multiple
          label={gettext("Related %{kind}s", kind: @kind)}
          value={selected_ids(@form, @related_field, current_ids(@related_current))}
          options={Enum.map(@siblings, &{&1.title, &1.id})}
        />
      </.inspector_section>

      <.inspector_section :if={@field_definitions != []} title={gettext("Custom fields")}>
        <.custom_field_input
          :for={definition <- @field_definitions}
          definition={definition}
          name={"#{@form.name}[custom_fields][#{definition.name}]"}
          value={custom_field_value(@form, definition.name)}
          errors={custom_field_errors(@form, definition.name)}
          options={custom_field_options(definition, @media, @reference_options)}
        />
      </.inspector_section>

      <%!-- Accessibility (#495) sits in its own section rather than
              under SEO, because it is a different question with a
              different audience — and because a finding buried three
              sections into "SEO & scheduling" is one an author fixing
              accessibility will never look for. Same checks underneath;
              see `Kiln.Advisory`. --%>
      <.inspector_section id="inspector-accessibility" title={gettext("Accessibility")}>
        <:aside>
          <.a11y_grade_badge report={@a11y_report} />
        </:aside>
        <%!-- Advisory only — nothing here ever blocks a save. The
                hard gate on alt text is `Validations.MediaAltText`
                (#403), which is a separate, opt-in policy. --%>
        <.a11y_findings
          :if={@a11y_report.findings != []}
          report={@a11y_report}
          class="rounded border border-base-content/10 bg-base-200/40 p-2"
        />
        <p :if={@a11y_report.findings == []} class="text-xs text-base-content/60">
          {ngettext(
            "No accessibility issues found in %{count} applicable check.",
            "No accessibility issues found in %{count} applicable checks.",
            @a11y_report.total,
            count: @a11y_report.total
          )}
        </p>
      </.inspector_section>

      <%!-- Compliance (#377). Rendered only when there is something to
              say: with claim checking off both checks report `:n_a`, so
              `total` is 0 and the section never appears — an install
              that never asked for a claims panel doesn't grow one. --%>
      <.inspector_section
        :if={@compliance_report.total > 0}
        id="inspector-compliance"
        title={gettext("Compliance")}
      >
        <:aside>
          <.compliance_grade_badge report={@compliance_report} />
        </:aside>
        <%!-- Advisory only. The hard gate is
                `Validations.ComplianceClaims`, which is separate and
                opt-in on top of this — see `KilnCMS.Compliance`. --%>
        <.compliance_findings
          :if={@compliance_report.findings != []}
          report={@compliance_report}
          class="rounded border border-base-content/10 bg-base-200/40 p-2"
        />
        <p :if={@compliance_report.findings == []} class="text-xs text-base-content/60">
          {ngettext(
            "No claim issues found in %{count} applicable check.",
            "No claim issues found in %{count} applicable checks.",
            @compliance_report.total,
            count: @compliance_report.total
          )}
        </p>
      </.inspector_section>

      <.inspector_section title={gettext("SEO & scheduling")}>
        <:aside>
          <.seo_grade_badge report={@seo_report} />
        </:aside>
        <%!-- Advisory only — nothing here ever blocks a save (#476). --%>
        <.seo_findings
          :if={@seo_report.findings != []}
          report={@seo_report}
          slug_customized?={@slug_customized?}
          class="rounded border border-base-content/10 bg-base-200/40 p-2"
        />
        <div :if={@seo_enabled? and @may_write? and @may_suggest_seo?}>
          <%!-- Gated on write access, not just the feature flag (#550):
                  a read-only viewer must not see a control that would bill
                  the org for a record they cannot edit. The server handler
                  re-checks; this only keeps the affordance honest.
                  `@may_suggest_seo?` adds the per-field grant (#868) —
                  `@may_write?` is `Ash.can?`, which cannot see a change,
                  so a field-granted editor was offered a billed run whose
                  result the save would then reject field by field. --%>
          <%!-- `type="button"` is mandatory: this sits inside the main
                  <.form>, so the default type would submit it. --%>
          <button
            type="button"
            phx-click="seo_suggest"
            disabled={@seo_drafting? or @conflict}
            class="btn btn-sm btn-default"
          >
            {gettext("Suggest with AI")}
            <.icon
              :if={@seo_drafting?}
              name="hero-arrow-path"
              class="ml-1 size-3 motion-safe:animate-spin"
            />
          </button>
          <%!-- Standing, non-dismissible: the operator chose a
                  third-party provider, the editor clicking didn't. --%>
          <p :if={@seo_egress?} class="mt-1 text-xs text-warning">
            {gettext(
              "Suggestions are generated by %{provider}. This page's title, excerpt and text are sent to that provider.",
              provider: @seo_provider
            )}
          </p>
          <.seo_suggestions
            draft={@seo_drafts}
            fields={suggested_fields(@seo_drafts)}
            dismissed={@seo_dismissed}
            locked_fields={@locked_fields}
          />
        </div>
        <div
          class={["relative", lock_ring(@locked_fields, "seo_title")]}
          {takeover_attrs(@locked_fields, "seo_title")}
        >
          <.input
            field={@form[:seo_title]}
            label={gettext("SEO title")}
            hint={
              gettext(
                "Overrides the title in search results and browser tabs. Falls back to the title."
              )
            }
            readonly={field_locked?(@locked_fields, "seo_title")}
            {field_attrs("seo_title")}
          />
          <.field_cursors field="seo_title" cursors={@cursors} />
        </div>
        <div
          class={["relative", lock_ring(@locked_fields, "seo_description")]}
          {takeover_attrs(@locked_fields, "seo_description")}
        >
          <.input
            field={@form[:seo_description]}
            type="textarea"
            label={gettext("SEO description")}
            hint={
              gettext(
                "The snippet shown under the title in search results (aim for ~155 characters)."
              )
            }
            readonly={field_locked?(@locked_fields, "seo_description")}
            {field_attrs("seo_description")}
          />
          <.field_cursors field="seo_description" cursors={@cursors} />
        </div>
        <div
          class={["relative", lock_ring(@locked_fields, "seo_keywords")]}
          {takeover_attrs(@locked_fields, "seo_keywords")}
        >
          <.input
            field={@form[:seo_keywords]}
            label={gettext("SEO keywords")}
            readonly={field_locked?(@locked_fields, "seo_keywords")}
            {field_attrs("seo_keywords")}
          />
          <p class="mt-1 text-xs text-base-content/60">
            {gettext("Comma-separated; the first keyphrase drives the auto-derived slug.")}
          </p>
          <.field_cursors field="seo_keywords" cursors={@cursors} />
        </div>
        <div
          class={["relative", lock_ring(@locked_fields, "seo_image")]}
          {takeover_attrs(@locked_fields, "seo_image")}
        >
          <.input
            field={@form[:seo_image]}
            label={gettext("Social image")}
            hint={gettext("Image shown when this page is shared on social media.")}
            placeholder="/uploads/cover.jpg"
            readonly={field_locked?(@locked_fields, "seo_image")}
            {field_attrs("seo_image")}
          />
          <%!-- The URL box stays for off-site absolute URLs; these
                  shortcuts cover the common cases (#476). --%>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="open_seo_image_picker"
              disabled={field_locked?(@locked_fields, "seo_image")}
              class="btn btn-sm btn-default"
            >
              {gettext("Choose from library")}
            </button>
            <button
              :if={@form[:featured_image_id].value not in [nil, ""]}
              type="button"
              phx-click="use_featured_image"
              disabled={field_locked?(@locked_fields, "seo_image")}
              class="btn btn-sm btn-default"
            >
              {gettext("Use featured image")}
            </button>
            <button
              :if={@form[:seo_image].value not in [nil, ""]}
              type="button"
              phx-click="clear_seo_image"
              disabled={field_locked?(@locked_fields, "seo_image")}
              class="text-sm text-base-content/70 hover:text-error"
            >
              {gettext("Remove")}
            </button>
          </div>
          <.field_cursors field="seo_image" cursors={@cursors} />
        </div>
        <.social_card form={@form} media={@media} current_org={@current_org} />
        <div
          class={["relative", lock_ring(@locked_fields, "canonical_url")]}
          {takeover_attrs(@locked_fields, "canonical_url")}
        >
          <.input
            field={@form[:canonical_url]}
            label={gettext("Canonical URL")}
            hint={
              gettext("The preferred URL, if this content is reachable at more than one address.")
            }
            readonly={field_locked?(@locked_fields, "canonical_url")}
            {field_attrs("canonical_url")}
          />
          <.field_cursors field="canonical_url" cursors={@cursors} />
        </div>
        <.input field={@form[:locale]} label={gettext("Locale")} />
        <%!-- The visible input edits local wall-clock time; the hidden
                input carries the UTC instant (UtcDatetimeInput hook).
                Keyed on editor_version so conflict reloads / restores
                remount it from the fresh form (as rich text does). --%>
        <div
          id={"scheduled-at-#{@editor_version}"}
          phx-hook="UtcDatetimeInput"
          phx-update="ignore"
        >
          <label
            for={"scheduled-at-local-#{@editor_version}"}
            class="mb-1 block text-sm font-medium"
          >
            {gettext("Scheduled publish at")}
          </label>
          <input
            type="datetime-local"
            id={"scheduled-at-local-#{@editor_version}"}
            data-local-input
            class="field-input"
          />
          <input
            type="hidden"
            name={@form[:scheduled_at].name}
            value={@form[:scheduled_at].value && to_string(@form[:scheduled_at].value)}
            data-utc-input
          />
          <p class="mt-1 text-xs text-base-content/60">
            {gettext("Shown in your local timezone; stored as UTC.")}
          </p>
        </div>
        <%!-- The embargo end — same local/UTC input pair as above. --%>
        <div
          id={"unpublish-at-#{@editor_version}"}
          phx-hook="UtcDatetimeInput"
          phx-update="ignore"
        >
          <label
            for={"unpublish-at-local-#{@editor_version}"}
            class="mb-1 block text-sm font-medium"
          >
            {gettext("Scheduled unpublish at")}
          </label>
          <input
            type="datetime-local"
            id={"unpublish-at-local-#{@editor_version}"}
            data-local-input
            class="field-input"
          />
          <input
            type="hidden"
            name={@form[:unpublish_at].name}
            value={@form[:unpublish_at].value && to_string(@form[:unpublish_at].value)}
            data-utc-input
          />
          <p class="mt-1 text-xs text-base-content/60">
            {gettext("Published content is taken back to draft at this time.")}
          </p>
        </div>
      </.inspector_section>

      <%!-- Internal links (#377). Loaded on an explicit click, never on
              mount: it costs a vector query plus a read per neighbour, and
              inspector sections are always expanded, so there is no "first
              open" to hang lazy loading off.

              `:if={@may_write?}` matches the SEO panel above and the
              Similar content section below — every control in the rail
              that spends work on a click is offered only to someone who
              could act on the result. --%>
      <.inspector_section :if={@may_write?} title={gettext("Internal links")}>
        <p class="text-xs text-base-content/60">
          {gettext("Related pages worth linking to from this one.")}
        </p>

        <p :if={@seo_links == []} class="text-xs text-base-content/60">
          {link_empty_reason(@record)}
        </p>

        <ul :if={@seo_links not in [nil, []]} class="space-y-1.5">
          <li
            :for={link <- @seo_links}
            class="rounded border border-base-content/10 bg-base-200/40 p-2"
          >
            <p class="text-xs font-medium">{link.title || link.slug}</p>
            <div class="mt-0.5 flex items-center gap-2">
              <code class="min-w-0 flex-1 truncate text-xs text-base-content/60">
                {link.path}
              </code>
              <%!-- Copy, not insert: mutating the block tree server-side
                      would fight the TipTap/Y.Doc editor. --%>
              <button
                type="button"
                id={"seo-link-copy-#{link.id}"}
                phx-hook="Clipboard"
                data-clipboard-text={link.path}
                aria-label={gettext("Copy link to %{title}", title: link.title || link.slug)}
                class="btn-link shrink-0 text-xs underline"
              >
                {gettext("Copy")}
              </button>
            </div>
          </li>
        </ul>

        <button
          type="button"
          phx-click="seo_links_refresh"
          disabled={@seo_links_loading?}
          class="btn btn-sm btn-default"
        >
          {if @seo_links == nil,
            do: gettext("Find related pages"),
            else: gettext("Refresh")}
          <.icon
            :if={@seo_links_loading?}
            name="hero-arrow-path"
            class="ml-1 size-3 motion-safe:animate-spin"
          />
        </button>
      </.inspector_section>

      <%!-- Content intelligence (#339). Same click-to-load contract as
              Internal links above, and deliberately the section below it:
              all three read the same embeddings, and an author who has
              just paid for one query is the one most likely to want the
              others. No `<form>` here — the Settings rail is already
              inside `id="page-editor"`'s form, and a nested one is
              dropped by the HTML parser.

              `:if={@may_write?}` for the reason the SEO panel above
              carries it (#550): everything in here either bills an
              embedding or ticks a tag, and neither is something a
              read-only reviewer should be offered. The handlers refuse
              server-side too — this only stops showing a control that
              would be declined. --%>
      <.inspector_section :if={@may_write?} title={gettext("Similar content")}>
        <p class="text-xs text-base-content/60">
          {gettext("Near-duplicates of this page, and tags its content suggests.")}
        </p>

        <p
          :if={@intel_duplicates == [] and @intel_tags == []}
          class="text-xs text-base-content/60"
        >
          {intel_empty_reason(@record)}
        </p>

        <div :if={@intel_duplicates not in [nil, []]} class="space-y-1.5">
          <%!-- `-ink`, not `text-warning` — the accents are tuned to
                  carry white on a solid fill and only reach ~2-4:1 as
                  text on a light surface (the standing rule from #543). --%>
          <h4 class="text-xs font-medium text-warning-ink">
            {ngettext(
              "%{count} possible duplicate",
              "%{count} possible duplicates",
              length(@intel_duplicates)
            )}
          </h4>

          <ul class="space-y-1.5">
            <li
              :for={dup <- @intel_duplicates}
              class="rounded border border-warning/40 bg-warning/10 p-2"
            >
              <p class="text-xs font-medium text-warning-ink">{dup.title || dup.slug}</p>
              <%!-- Opens in a new tab: this is a *different* document,
                      and navigating away would abandon unsaved edits. --%>
              <a
                href={~p"/editor/content/#{dup.type}/#{dup.id}"}
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs text-warning-ink underline"
              >
                {gettext("Open %{type}", type: dup.type)} &nearr;
                <span class="sr-only">{gettext("(opens in a new tab)")}</span>
              </a>
            </li>
          </ul>
        </div>

        <div :if={@intel_tags not in [nil, []]} class="space-y-1.5">
          <h4 class="text-xs font-medium">{gettext("Suggested tags")}</h4>

          <div class="flex flex-wrap gap-1.5">
            <%!-- Ticks the tag in the picker above rather than writing
                    to the record: it saves with everything else, and
                    unticking the checkbox undoes it. --%>
            <button
              :for={suggestion <- @intel_tags}
              type="button"
              phx-click="intel_add_tag"
              phx-value-id={suggestion.tag.id}
              class="inline-flex items-center gap-1 rounded border border-base-content/20 px-2 py-1 text-xs hover:bg-base-200"
            >
              <.icon name="hero-plus" class="size-3" />
              {suggestion.tag.name}
            </button>
          </div>
        </div>

        <button
          type="button"
          phx-click="content_intel_refresh"
          disabled={@intel_loading?}
          class="btn btn-sm btn-default"
        >
          {if @intel_duplicates == nil,
            do: gettext("Analyze content"),
            else: gettext("Refresh")}
          <.icon
            :if={@intel_loading?}
            name="hero-arrow-path"
            class="ml-1 size-3 motion-safe:animate-spin"
          />
        </button>
      </.inspector_section>
    </div>
    """
  end
end
