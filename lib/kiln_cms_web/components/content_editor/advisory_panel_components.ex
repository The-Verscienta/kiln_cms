defmodule KilnCMSWeb.ContentEditor.AdvisoryPanelComponents do
  @moduledoc """
  Advisory-surface panels for the content editor that don't already live in
  `KilnCMSWeb.SeoComponents`/`AccessibilityComponents`/`ComplianceComponents`:
  the SEO suggestion cards and the per-block AI-assist panel (#1311).

  Moved verbatim from `KilnCMSWeb.ContentEditorLive`. Events stay untargeted,
  so they keep landing on the enclosing LiveView.
  """

  use KilnCMSWeb, :html

  import KilnCMSWeb.ContentEditor.Shared,
    only: [field_locked?: 2, seo_field_label: 1, suggested_value: 2]

  defp assist_action_label(:draft), do: gettext("Draft")
  defp assist_action_label(:continue), do: gettext("Continue")
  defp assist_action_label(:summarize), do: gettext("Summarize")
  defp assist_action_label(:rewrite), do: gettext("Improve")
  defp assist_action_label(:shorten), do: gettext("Shorten")
  defp assist_action_label(:expand), do: gettext("Expand")

  defp assist_action_hint(:draft),
    do: gettext("Writes new prose from your instruction. Describe what this section should say.")

  defp assist_action_hint(:continue),
    do: gettext("Carries on from where this block stops, in the same voice.")

  defp assist_action_hint(:summarize),
    do: gettext("Condenses this block into a single short paragraph.")

  defp assist_action_hint(:rewrite),
    do: gettext("Rewrites this block more clearly, keeping every fact and roughly the length.")

  defp assist_action_hint(:shorten), do: gettext("Cuts this block to about half its length.")

  defp assist_action_hint(:expand),
    do: gettext("Adds detail drawn from this block and the rest of the page.")

  defp assist_action_hint(_action), do: ""

  attr :draft, :any, required: true
  attr :fields, :list, required: true
  attr :dismissed, :any, required: true
  attr :locked_fields, :any, required: true

  # Proposed values, one card per field, each accepted or dismissed on its own.
  # Nothing here writes anything — every value needs a human click, which is
  # the primary control on a generated string reaching a public `<meta>` tag.
  def seo_suggestions(assigns) do
    assigns = assign(assigns, :pending, Enum.reject(assigns.fields, &(&1 in assigns.dismissed)))

    ~H"""
    <div :if={@pending != []} class="mt-2 space-y-2">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-medium text-base-content/70">
          {gettext("Suggestions")}
        </span>
        <div class="flex items-center gap-2">
          <button type="button" phx-click="seo_accept_all" class="btn-link text-xs underline">
            {gettext("Use all")}
          </button>
          <button
            type="button"
            phx-click="seo_dismiss_all"
            class="btn-link text-xs text-base-content/60 underline"
          >
            {gettext("Dismiss")}
          </button>
        </div>
      </div>

      <div
        :for={field <- @pending}
        class="rounded border border-base-content/15 bg-base-200/40 p-2"
      >
        <p class="text-xs font-medium text-base-content/60">{seo_field_label(field)}</p>
        <p class="mt-0.5 text-xs break-words">{seo_suggestion_value(@draft, field)}</p>
        <div class="mt-1.5 flex items-center gap-2">
          <button
            type="button"
            phx-click="seo_accept"
            phx-value-field={field}
            disabled={field_locked?(@locked_fields, field)}
            class="btn btn-sm btn-default"
          >
            {gettext("Use")}
          </button>
          <button
            type="button"
            phx-click="seo_dismiss"
            phx-value-field={field}
            class="text-xs text-base-content/60 hover:text-base-content"
          >
            {gettext("Dismiss")}
          </button>
          <span class="ml-auto text-xs text-base-content/50">
            {seo_suggestion_length(@draft, field)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp seo_suggestion_value(draft, field), do: suggested_value(draft, field)

  # Character count against the band the analyzer checks, so the author can see
  # a proposal is in range before accepting it.
  defp seo_suggestion_length(draft, field) do
    length = draft |> suggested_value(field) |> to_string() |> String.length()

    case field do
      "seo_title" -> "#{length}/#{KilnCMS.Seo.title_max()}"
      "seo_description" -> "#{length}/#{KilnCMS.Seo.description_max()}"
      _ -> ""
    end
  end

  attr :block_id, :string, required: true
  attr :open?, :boolean, required: true
  attr :action, :atom, required: true
  attr :running?, :boolean, required: true
  attr :result, :any, default: nil
  attr :egress?, :boolean, required: true
  attr :provider, :string, default: nil
  attr :conflict, :boolean, required: true

  # Per-block AI assist (#60): the second half of this issue, the first being
  # the metadata drafting in the SEO panel.
  #
  # Sits *outside* the block's `phx-update="ignore"` host — LiveView cannot
  # patch inside one, so a panel rendered in there would never update. The
  # suggestion is shown as plain paragraphs and applied only by a human click,
  # which is the primary control on generated prose reaching a published page.
  def assist_panel(assigns) do
    ~H"""
    <div class="mt-2">
      <%!-- `type="button"` is mandatory: this sits inside the main <.form>, so
            the default type would submit it. --%>
      <button
        type="button"
        phx-click={if @open?, do: "assist_close", else: "assist_open"}
        phx-value-bid={@block_id}
        aria-expanded={to_string(@open?)}
        class="inline-flex items-center gap-1 rounded border border-base-content/20 px-2 py-0.5 text-xs hover:bg-base-200"
      >
        <.icon name="hero-sparkles" class="size-3.5" />{gettext("AI assist")}
      </button>

      <div
        :if={@open?}
        class="mt-2 space-y-2 rounded border border-base-content/15 bg-base-200/40 p-2"
      >
        <div
          role="group"
          aria-label={gettext("What should the model do?")}
          class="flex flex-wrap gap-1"
        >
          <button
            :for={action <- KilnCMS.Assist.Action.all()}
            type="button"
            phx-click="assist_action"
            phx-value-action={action.id}
            aria-pressed={to_string(@action == action.id)}
            class={[
              "rounded border px-2 py-0.5 text-xs",
              if(@action == action.id,
                do: "border-primary bg-primary text-primary-content",
                else: "border-base-content/20 hover:bg-base-200"
              )
            ]}
          >
            {assist_action_label(action.id)}
          </button>
        </div>

        <p class="text-xs text-base-content/70">{assist_action_hint(@action)}</p>

        <%!-- Unprefixed name, so the main form's `validate` (which reads only
              "form") never sees it; its own phx-change keeps typing here from
              marking the record dirty.

              `phx-debounce="blur"`, not a millisecond value: this input sits
              inside the main content form, and LiveView serializes the WHOLE
              enclosing form on every change — title, every SEO field, every
              block's inputs. On a timer that is the entire form uploaded every
              few hundred milliseconds so the server can read one key. Clicking
              Generate blurs the input first, so the value still lands before
              the run.

              The value is deliberately NOT fed back: the browser owns the text
              (the panel is freshly mounted each time it opens, always empty),
              which keeps `@assist_instruction` out of the block comprehension —
              reading it there re-rendered and re-sent every block on the page
              per keystroke — and keeps the server from fighting the caret. --%>
        <%!-- A textarea, not a text input: a single-line input inside a form
              that has a submit button submits it on Enter, so typing an
              instruction and pressing Enter saved the record — publishing to
              the live URL — instead of generating anything. --%>
        <textarea
          name="assist_instruction"
          rows="2"
          phx-change="assist_instruction"
          phx-debounce="blur"
          maxlength={KilnCMS.Assist.max_instruction_chars()}
          aria-label={gettext("Instruction for the model")}
          placeholder={gettext("Optional: what should it say? (required for Draft)")}
          class="field-input text-xs"
        ></textarea>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="assist_run"
            phx-value-bid={@block_id}
            disabled={@running? or @conflict}
            class="btn btn-sm btn-default"
          >
            {gettext("Generate")}
            <.icon
              :if={@running?}
              name="hero-arrow-path"
              class="ml-1 size-3 motion-safe:animate-spin"
            />
          </button>
          <button
            type="button"
            phx-click="assist_close"
            class="btn-link text-xs text-base-content/60 underline hover:text-base-content"
          >
            {gettext("Close")}
          </button>
        </div>

        <%!-- Standing, non-dismissible: the operator chose a third-party
              provider, the editor clicking didn't. --%>
        <p :if={@egress?} class="text-xs text-warning">
          {gettext(
            "Text is generated by %{provider}. This block's content, the page's title and headings, and your instruction are sent to that provider.",
            provider: @provider
          )}
        </p>

        <div :if={@result} class="rounded border border-base-content/15 bg-base-100 p-2">
          <p class="text-xs font-medium text-base-content/60">
            {gettext("Suggestion")} · {ngettext("%{count} word", "%{count} words", @result.word_count,
              count: @result.word_count
            )}
          </p>
          <%!-- Rendered as text nodes, never raw: a model talked into emitting
                markup shows the markup, which nobody clicks Insert on. --%>
          <p :for={paragraph <- @result.paragraphs} class="mt-1 text-xs break-words">
            {paragraph}
          </p>
          <p :if={@result.truncated?} class="mt-1 text-xs text-base-content/50">
            {gettext("Cut to fit the length limit.")}
          </p>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="assist_apply"
              phx-value-mode="insert"
              class="btn btn-sm btn-default"
            >
              {gettext("Insert at cursor")}
            </button>
            <button
              type="button"
              phx-click="assist_apply"
              phx-value-mode="replace"
              data-confirm={
                gettext("Replace everything in this block? You can undo it in the editor.")
              }
              class="btn btn-default px-2 py-0.5 text-xs"
            >
              {gettext("Replace block")}
            </button>
            <button
              type="button"
              phx-click="assist_dismiss"
              class="btn-link text-xs text-base-content/60 underline hover:text-base-content"
            >
              {gettext("Dismiss")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
