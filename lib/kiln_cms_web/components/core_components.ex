defmodule KilnCMSWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  on top of KilnCMS's own semantic design tokens (defined in `assets/css/app.css`
  via `@theme`): `base-100`/`base-200`/`base-300`/`base-content` for surfaces and
  text, `primary`/`secondary`/`accent`/`neutral` for brand, and
  `info`/`success`/`warning`/`error` for status — used as ordinary Tailwind color
  utilities (`bg-base-100`, `text-error`, …). Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Phoenix.LiveView.JS

  # Shared field styling (token-based; no DaisyUI). Used by input/select/textarea.
  defp input_base do
    "w-full rounded-lg border border-base-content/15 bg-base-100 px-3 py-2 text-sm " <>
      "text-base-content transition placeholder:text-base-content/70 focus:border-primary/50 " <>
      "focus:outline-none focus:ring-2 focus:ring-primary/20 disabled:cursor-not-allowed disabled:opacity-60"
  end

  defp input_error_class, do: "border-error/60 focus:border-error/60 focus:ring-error/20"
  defp field_label_class, do: "mb-1 block text-sm font-medium text-base-content"

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-3 right-3 z-50"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-lg border bg-base-100 px-4 py-3 text-base-content shadow-lg w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "border-info/30",
        @kind == :error && "border-error/30"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0 text-info" />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-error"
        />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any
  attr :variant, :string, values: ~w(primary danger ghost)
  attr :size, :string, default: nil, values: [nil, "sm"]
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # The `.btn` family lives in the Kiln component kit (assets/css/app.css) so
    # buttons stay identical whether written as `<.button>` or a raw `class="btn
    # …"` in a template. See docs/design-language.md.
    variant =
      case assigns[:variant] do
        "primary" -> "btn-primary"
        "danger" -> "btn-danger"
        "ghost" -> "btn-ghost"
        nil -> "btn-default"
      end

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", variant, assigns[:size] == "sm" && "btn-sm"]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a small status pill.

  ## Examples

      <.badge>draft</.badge>
      <.badge variant="success">published</.badge>

  `outline` is the quieter tone: use it for a badge that qualifies another
  badge next to it, so the pair reads as primary-then-refinement.
  """
  attr :variant, :string,
    default: "neutral",
    values: ~w(neutral outline primary success warning error info)

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    # Pale accent tint + the matching `*-ink` token, which is the accent
    # darkened for light surfaces and the raw accent in dark (see app.css).
    # The bare accents only reach ~2.1-4.2:1 as text on their own tint in
    # light mode, and `text-warning-content` — ink meant for a SOLID fill —
    # inverts to 1.4:1 on the tint in dark.
    tones = %{
      "neutral" => "bg-base-200 text-base-content/70",
      "outline" => "border border-base-content/25 text-base-content/70",
      "primary" => "bg-primary/12 text-primary-ink",
      "success" => "bg-success/15 text-success-ink",
      "warning" => "bg-warning/20 text-warning-ink",
      "error" => "bg-error/12 text-error-ink",
      "info" => "bg-info/12 text-info-ink"
    }

    assigns = assign(assigns, :tone, Map.fetch!(tones, assigns.variant))

    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
      @tone,
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders a small status pill for content workflow states (draft / in_review /
  published / archived). The label is translated via Gettext.

  ## Examples

      <.state_badge state={:draft} />
      <.state_badge state={:published} />
  """
  attr :state, :atom, required: true
  attr :class, :any, default: nil

  def state_badge(assigns) do
    variant =
      case assigns.state do
        :published -> "success"
        :in_review -> "warning"
        :archived -> "neutral"
        _ -> "info"
      end

    assigns =
      assigns
      |> assign(:variant, variant)
      |> assign(:label, state_label(assigns.state))

    ~H"""
    <.badge variant={@variant} class={@class}>{@label}</.badge>
    """
  end

  @doc "Returns a translated human label for a content workflow state atom."
  def state_label(state) do
    case state do
      :draft -> gettext("Draft")
      :in_review -> gettext("In review")
      :published -> gettext("Published")
      :archived -> gettext("Archived")
      _ -> to_string(state)
    end
  end

  @doc """
  Renders a bagua trigram: three stacked lines, each solid (yang) or broken
  (yin), given bottom line first. The console uses trigrams two ways — fixed
  marks on the overview's bagua tiles, and per-item status glyphs derived from
  workflow bits (see `content_trigram/1`).

  ## Examples

      <.trigram lines={[false, true, true]} label="xun · wind" />
  """
  attr :lines, :list, required: true, doc: "three booleans, bottom line first; true = solid"
  attr :label, :string, required: true, doc: "accessible name, also the hover tooltip"
  attr :class, :any, default: nil

  def trigram(assigns) do
    ~H"""
    <svg
      viewBox="0 0 20 13"
      class={["inline-block h-3 w-5 shrink-0", @class]}
      role="img"
      aria-label={@label}
    >
      <title>{@label}</title>
      <%= for {solid?, row} <- Enum.with_index(Enum.reverse(@lines)) do %>
        <rect :if={solid?} x="0" y={row * 5} width="20" height="3" rx="1" fill="currentColor" />
        <rect :if={!solid?} x="0" y={row * 5} width="8.5" height="3" rx="1" fill="currentColor" />
        <rect :if={!solid?} x="11.5" y={row * 5} width="8.5" height="3" rx="1" fill="currentColor" />
      <% end %>
    </svg>
    """
  end

  @doc """
  The composite content-status trigram: three workflow bits rendered as one of
  the eight trigrams — published (bottom line), a variant in every configured
  locale (middle), a pending scheduled transition (top); solid = yes. The
  `<.state_badge>` next to it spells the workflow state out; this is the
  at-a-glance composite, named in the tooltip.

  ## Examples

      <.content_trigram published={true} translated={false} scheduled={true} />
  """
  attr :published, :boolean, required: true
  attr :translated, :boolean, required: true
  attr :scheduled, :boolean, required: true
  attr :class, :any, default: nil

  def content_trigram(assigns) do
    lines = [assigns.published, assigns.translated, assigns.scheduled]

    label =
      Enum.join(
        [
          trigram_name(lines),
          if(assigns.published, do: gettext("published"), else: gettext("not published")),
          if(assigns.translated, do: gettext("translated"), else: gettext("translation gaps")),
          if(assigns.scheduled, do: gettext("scheduled"), else: gettext("no schedule"))
        ],
        " · "
      )

    assigns = assign(assigns, lines: lines, label: label)

    ~H"""
    <.trigram lines={@lines} label={@label} class={@class} />
    """
  end

  # The pinyin name and image of the trigram whose lines (bottom first) are
  # the given booleans — the tooltip vocabulary for `content_trigram/1`.
  defp trigram_name([true, true, true]), do: "qian · heaven"
  defp trigram_name([true, true, false]), do: "dui · lake"
  defp trigram_name([true, false, true]), do: "li · fire"
  defp trigram_name([true, false, false]), do: "zhen · thunder"
  defp trigram_name([false, true, true]), do: "xun · wind"
  defp trigram_name([false, true, false]), do: "kan · water"
  defp trigram_name([false, false, true]), do: "gen · mountain"
  defp trigram_name([false, false, false]), do: "kun · earth"

  @doc """
  A modal dialog or side drawer — scrim, focus trap, Escape, close button (#693).

  Five hand-rolled shells used to carry these seven invariants each — scrim,
  `phx-hook="FocusTrap"`, `role="dialog"`, `aria-modal`, `aria-labelledby`,
  `tabindex="-1"`, Escape — and they had already drifted apart on `z-50` vs
  `z-40`, `bg-black/20` vs `bg-black/40`, and five different close-event names.
  Drift in a decorative class is cosmetic; drift in `aria-labelledby` is a
  dialog a screen reader cannot announce, and nothing renders differently when
  that happens.

  ## Escape is scoped to the dialog, not the window

  Every one of those shells bound `phx-window-keydown`. Two of them could be open
  at once — the image picker over the compare modal — and then one Escape press
  dispatched *both* close events while two focus traps fought over focus.

  Here it is `data-close-event`, handled by the `FocusTrap` hook. That indirection
  is not a preference: LiveView's key binding reads the attribute off the **exact**
  event target and does not walk ancestors, so a `phx-keydown` on the panel never
  fires — this hook has just moved focus to a button inside it. A plain listener
  in the hook gets the bubbled event from whatever descendant holds focus, and
  since the dialogs are DOM siblings exactly one of them sees any given press:
  the one the person is actually in. Nesting is well-defined rather than
  accidental.

  The cost of that scoping is that Escape needs focus to be *inside* the panel,
  and `FocusTrap` currently only traps Tab — so focus can leave by other routes
  (Safari does not focus a `<button>` on click) and Escape goes quiet until it
  comes back. The scrim and the ✕ still close the dialog. Tracked as #1046.

  ## Variants

    * `:dialog` — centred, the shape a comparison or a confirmation wants.
    * `:drawer` — full-height on the right, the shape a picker wants; it dims the
      page it is beside rather than covering it, so the scrim is lighter.

  The scrim, the trap and the ARIA wiring are not overridable, because those are
  the reason this exists. Neither is the panel's own layout: an earlier `class`
  attribute *replaced* those classes rather than adding to them, so a caller
  reaching for "just a different max-width" would have silently lost
  `flex flex-col`, `bg-base-100` and the drawer's positioning and got an
  unpositioned transparent panel. No caller wanted it; a variant is the honest
  way to add a new shape.

      <.modal id="image-picker-dialog" on_close="close_picker" variant={:drawer}>
        <:title>{gettext("Choose an image")}</:title>
        …
      </.modal>
  """
  attr :id, :string, required: true, doc: "id of the dialog panel; `-title` labels it"
  attr :on_close, :string, required: true, doc: "event pushed by Escape, the scrim and the ✕"
  attr :variant, :atom, default: :dialog, values: [:dialog, :drawer]
  attr :rest, :global

  slot :title, required: true
  slot :subtitle, doc: "rendered under the title, inside the labelled header"
  slot :inner_block, required: true

  def modal(assigns) do
    assigns =
      assigns
      |> assign(:panel_class, panel_class(assigns.variant))
      |> assign(:scrim_class, scrim_class(assigns.variant))

    ~H"""
    <div class="fixed inset-0 z-50">
      <div class={["absolute inset-0", @scrim_class]} phx-click={@on_close} aria-hidden="true"></div>
      <div
        id={@id}
        phx-hook="FocusTrap"
        data-close-event={@on_close}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        tabindex="-1"
        class={@panel_class}
        {@rest}
      >
        <div class="flex items-start justify-between gap-4 border-b border-base-content/10 p-4">
          <div class="min-w-0">
            <h2 id={"#{@id}-title"} class="truncate text-lg font-medium">{render_slot(@title)}</h2>
            <div :if={@subtitle != []} class="mt-1 text-sm text-base-content/70">
              {render_slot(@subtitle)}
            </div>
          </div>
          <button
            type="button"
            phx-click={@on_close}
            aria-label={gettext("Close")}
            class="shrink-0 rounded p-1 text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # A drawer sits BESIDE the page rather than over it, so its scrim only dims —
  # the editor stays readable while you pick from the library next to it.
  defp scrim_class(:drawer), do: "bg-black/20"
  defp scrim_class(:dialog), do: "bg-black/40"

  defp panel_class(:drawer) do
    "drawer-in absolute inset-y-0 right-0 flex w-full max-w-md flex-col " <>
      "border-l border-base-content/10 bg-base-100 shadow-xl"
  end

  defp panel_class(:dialog) do
    "absolute inset-4 mx-auto flex max-w-4xl flex-col overflow-hidden rounded-lg " <>
      "border border-base-content/10 bg-base-100 shadow-xl"
  end

  @doc """
  Renders a centered empty-state: an icon, a message, optional body and action.

  ## Examples

      <.empty_state icon="hero-photo" title="No media yet">
        Upload an image to get started.
      </.empty_state>
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed",
      "border-base-content/15 bg-base-100 px-6 py-12 text-center",
      @class
    ]}>
      <.icon name={@icon} class="size-8 text-base-content/30" />
      <div class="space-y-1">
        <p class="text-sm font-medium text-base-content">{@title}</p>
        <p :if={@inner_block != []} class="mx-auto max-w-sm text-sm text-base-content/55">
          {render_slot(@inner_block)}
        </p>
      </div>
      <div :if={@action != []} class="mt-1">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil, doc: "help text shown under the field"
  attr :required, :boolean, default: false, doc: "marks the label and the input required"
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="flex items-center gap-2 text-sm text-base-content">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            required={@required}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@errors != [] && error_id(@id)}
            class={@class || "size-4 rounded border border-base-content/30 accent-primary"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.field_errors id={error_id(@id)} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <.field_wrapper id={@id} label={@label} required={@required} hint={@hint} errors={@errors}>
      <select
        id={@id}
        name={@name}
        required={@required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && error_id(@id)}
        class={[
          @class || input_base() <> " cursor-pointer",
          @errors != [] && (@error_class || input_error_class())
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
    </.field_wrapper>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <.field_wrapper id={@id} label={@label} required={@required} hint={@hint} errors={@errors}>
      <textarea
        id={@id}
        name={@name}
        required={@required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && error_id(@id)}
        class={[
          @class || input_base() <> " min-h-24",
          @errors != [] && (@error_class || input_error_class())
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
    </.field_wrapper>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <.field_wrapper id={@id} label={@label} required={@required} hint={@hint} errors={@errors}>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        required={@required}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && error_id(@id)}
        class={[
          @class || input_base(),
          @errors != [] && (@error_class || input_error_class())
        ]}
        {@rest}
      />
    </.field_wrapper>
    """
  end

  # The id of a field's error container, for `aria-describedby` (#172).
  defp error_id(id), do: "#{id}-error"

  # Renders a field's validation errors inside an id'd container so the input can
  # reference them via aria-describedby. Screen readers announce them on
  # validate/submit failure (the input is also marked aria-invalid). #172
  attr :id, :string, required: true
  attr :errors, :list, default: []

  defp field_errors(assigns) do
    ~H"""
    <div :if={@errors != []} id={@id}>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # A field label with an optional required marker (Theme D field chrome).
  attr :label, :string, default: nil
  attr :required, :boolean, default: false

  defp field_label(assigns) do
    ~H"""
    <span :if={@label} class={field_label_class()}>
      {@label}<span
        :if={@required}
        class="ml-0.5 text-error"
        title={gettext("Required")}
        aria-hidden="true"
      >*</span>
    </span>
    """
  end

  # Help text under a field (Theme D field chrome).
  attr :hint, :string, default: nil

  defp field_hint(assigns) do
    ~H"""
    <p :if={@hint} class="mt-1 text-xs text-base-content/60">{@hint}</p>
    """
  end

  # The shared label + control + errors + hint scaffold, so the select/textarea/
  # text `input` clauses don't each re-implement it (and can't drift on the
  # required-marker / help-text wiring). The control is the inner block.
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :required, :boolean, default: false
  attr :hint, :string, default: nil
  attr :errors, :list, default: []
  slot :inner_block, required: true

  defp field_wrapper(assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <.field_label label={@label} required={@required} />
        {render_slot(@inner_block)}
      </label>
      <.field_errors id={error_id(@id)} errors={@errors} />
      <.field_hint hint={@hint} />
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col} scope="col">{col[:label]}</th>
          <th :if={@action != []} scope="col">
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(KilnCMSWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(KilnCMSWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
