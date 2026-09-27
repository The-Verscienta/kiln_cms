defmodule KilnCMSWeb.AutomationLive.ConfigFields do
  @moduledoc """
  The settings half of an automation rule: one real input per key a reaction
  accepts, where there used to be a JSON textarea an admin had to hand-write.

  Which keys a reaction takes, which it requires, and each key's type all come
  from `KilnCMS.Automation.Validations.ActionConfig` — the table that refuses a
  save — so this form cannot offer a key the save would refuse, or leave out
  one it requires. What this module adds is only what that table can't say:
  a label, help text, and which widget a key renders as (`meta/1`). Every key
  in the table has an entry, and `automation_live_test.exs` fails when one
  doesn't, so adding a key to a reaction without a label is a red suite rather
  than a raw key name shown to a non-developer.

  ## Params → config

  Inputs post as `rule[config][<key>]`, strings like every form field.
  `coerce/2` turns them into the `config` map the table accepts: blanks are
  dropped (an empty optional field means "use the default", not `""`, which
  the table refuses), the toggle becomes the JSON boolean, and day counts
  become integers. Casting here is safe in a way it isn't in the validation —
  the widget that produced the value is known, so a checkbox's `"true"` can
  only mean `true`. Keys outside the selected action's shape are dropped too:
  switching the action select posts the previous action's fields once, before
  the form re-renders with the new ones.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.Automation.RuleWorker
  alias KilnCMS.Automation.Validations.ActionConfig
  alias KilnCMS.Social.Composer
  alias Phoenix.LiveView.ColocatedHook

  @doc """
  The UI description of one config key — `%{label, widget, ...}` — or `nil`
  for a key this form doesn't know how to render.

  `:widget` is one of `:email`, `:text`, `:textarea`, `:number`, `:toggle`,
  `:deliver_as`, or `{:select, source}` where `source` names an option list
  the LiveView loads (`:users`, `:segments`, `:providers`). `:tokens` names
  whose `{{placeholder}}` set a template field offers as chips — `:content`
  (`RuleWorker.template_tokens/0`) or `:social` (`Composer.template_tokens/0`).
  Which fields apply under which `deliver_as` is not here: that is
  `ActionConfig.applicable?/3`, beside the rule that enforces it.
  """
  @spec meta(String.t()) :: map() | nil
  def meta("to"),
    do: %{
      label: gettext("Send to"),
      widget: :email,
      placeholder: "team@example.com"
    }

  def meta("subject"),
    do: %{
      label: gettext("Subject line"),
      widget: :text,
      placeholder: gettext("Leave blank for the default"),
      tokens: :content
    }

  def meta("body"),
    do: %{
      label: gettext("Message"),
      widget: :textarea,
      placeholder: gettext("Leave blank for the default message"),
      tokens: :content
    }

  def meta("topic"),
    do: %{
      label: gettext("Broadcast channel"),
      widget: :text,
      placeholder: "automation",
      hint: gettext("The internal channel listeners subscribe to. Defaults to “automation”.")
    }

  def meta("segment_id"),
    do: %{
      label: gettext("Audience"),
      widget: {:select, :segments},
      prompt: gettext("All confirmed subscribers")
    }

  def meta("provider"),
    do: %{
      label: gettext("Post to"),
      widget: {:select, :providers},
      prompt: gettext("Choose a network"),
      hint: gettext("Posts from every enabled account on that network (see Social accounts).")
    }

  def meta("template"),
    do: %{
      label: gettext("Post text"),
      widget: :textarea,
      placeholder: gettext("Leave blank to post the title, summary and link"),
      tokens: :social
    }

  def meta("deliver_as"), do: %{label: gettext("Send findings as"), widget: :deliver_as}

  def meta("assignee"),
    do: %{
      label: gettext("Assign to"),
      widget: {:select, :users},
      prompt: gettext("Choose a person")
    }

  def meta("due_in_days"),
    do: %{
      label: gettext("Due after (days)"),
      widget: :number,
      placeholder: gettext("Default")
    }

  def meta("allow_egress"),
    do: %{
      label: gettext("Allow sending page text to an external AI provider"),
      widget: :toggle,
      hint:
        gettext(
          "Needed when the configured model runs off-site. Leave off to keep content on this server — the rule then does nothing with an off-site model."
        )
    }

  def meta("assignee_id"),
    do: %{
      label: gettext("Fallback assignee"),
      widget: {:select, :users},
      prompt: gettext("No fallback"),
      hint:
        gettext(
          "Tasks go to the content's author. This person gets them when the author can't take one."
        )
    }

  def meta("note"),
    do: %{
      label: gettext("Task note"),
      widget: :textarea,
      placeholder: "Review due — {{title}}",
      tokens: :content
    }

  def meta(_key), do: nil

  @doc """
  The fields to render for `action` given the current `config`, in order:
  `%{key, type, required?, meta}`.

  The intelligence reactions hide the fields their current `deliver_as`
  doesn't use, so a "comment" rule shows no "Send to" box it would ignore.
  """
  @spec fields(atom() | nil, map()) :: [map()]
  def fields(action, config) do
    case ActionConfig.shape(action) do
      nil ->
        []

      shape ->
        required = ActionConfig.required_keys(action, config)

        (shape.required ++ shape.optional)
        |> Enum.filter(fn {key, _type} -> ActionConfig.applicable?(action, key, config) end)
        |> Enum.map(fn {key, type} ->
          %{key: key, type: type, required?: key in required, meta: meta(key) || fallback(key)}
        end)
        # A toggle reads as a footnote to the fields above it, not a lead-in.
        |> Enum.sort_by(&(&1.meta.widget == :toggle))
    end
  end

  # Rendered rather than crashing if a key ever lands in the table without an
  # entry above — the test that forbids that is the real guard.
  defp fallback(key), do: %{label: Phoenix.Naming.humanize(key), widget: :text}

  @doc "Casts `rule[config]` form params to the `config` map `action` accepts."
  @spec coerce(atom() | nil, term()) :: map()
  def coerce(action, params) when is_map(params) do
    case ActionConfig.shape(action) do
      nil ->
        %{}

      shape ->
        for {key, type} <- shape.required ++ shape.optional,
            {:ok, value} <- [cast(type, Map.get(params, key))],
            into: %{},
            do: {key, value}
    end
  end

  def coerce(_action, _params), do: %{}

  defp cast(_type, nil), do: :skip

  defp cast(type, value) when is_binary(value) do
    if String.trim(value) == "", do: :skip, else: cast_present(type, value)
  end

  # Already typed — a stored config re-rendered and re-posted by a test, say.
  defp cast(_type, value), do: {:ok, value}

  # An unchecked toggle is left out rather than stored as `false`: absent is
  # already "off" everywhere `allow_egress` is read, and it keeps the stored
  # config to what was actually switched on.
  defp cast_present(:boolean, "true"), do: {:ok, true}
  defp cast_present(:boolean, _value), do: :skip

  # Not a number: passed through as typed, so the table's own message names
  # it beside the field instead of the value silently vanishing.
  defp cast_present(type, value) when type in [:integer, :day_count] do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:ok, value}
    end
  end

  # Templates keep their spacing; every other string is an identifier or an
  # address, where a stray space makes a value that looks right and matches
  # nothing ("editorial " is a broadcast channel no listener is on).
  defp cast_present(:template, value), do: {:ok, value}
  defp cast_present(_type, value), do: {:ok, String.trim(value)}

  # --- render ----------------------------------------------------------------

  attr :form, :any, required: true, doc: "the rule form"
  attr :action, :atom, required: true, doc: "the reaction currently selected"
  attr :options, :map, required: true, doc: "option lists for `{:select, source}` widgets"

  @doc "The generated settings inputs for the selected reaction."
  def config_fields(assigns) do
    config = config_value(assigns.form)

    errors = if submitted_once?(assigns.form), do: assigns.form[:config].errors, else: []
    fields = fields(assigns.action, config)
    keys = Enum.map(fields, & &1.key)

    assigns =
      assigns
      |> assign(:config, config)
      |> assign(:fields, fields)
      |> assign(:errors, errors)
      # An error carries its key as `config_key` (`ActionConfig.error/2`); one
      # for a field on screen is shown under that field, anything else here.
      |> assign(
        :loose_errors,
        for(
          {msg, opts} <- errors,
          opts[:config_key] not in keys,
          do: translate_error({msg, opts})
        )
      )

    ~H"""
    <fieldset class="space-y-3 rounded-lg border border-base-content/10 bg-base-200/30 p-4">
      <legend class="px-1 text-sm font-medium">{gettext("Settings")}</legend>

      <p :if={@fields == []} class="text-sm text-base-content/60">
        {gettext("Nothing to set up — this action runs as soon as its trigger fires.")}
      </p>

      <.config_field
        :for={field <- @fields}
        field={field}
        id={"#{@form.id}_config_#{field.key}"}
        name={"#{@form.name}[config][#{field.key}]"}
        value={Map.get(@config, field.key)}
        errors={
          for {msg, opts} <- @errors, opts[:config_key] == field.key, do: field_message(msg, opts)
        }
        options={@options}
      />

      <.field_error :for={msg <- @loose_errors} msg={msg} />
    </fieldset>
    """
  end

  # Not before the first save attempt: picking "Task" would otherwise flag
  # "Assign to" red before anyone had a chance to fill it in. Same rule
  # AshPhoenix applies to the form's own fields.
  defp submitted_once?(%Phoenix.HTML.Form{source: %AshPhoenix.Form{submitted_once?: true}}),
    do: true

  defp submitted_once?(_form), do: false

  # `ActionConfig`'s messages are written for a config map ("Action config is
  # missing `assignee`…"). Under the field that key belongs to, the field's
  # label already says which setting it is, so the message says only what is
  # wrong with it — read from the error's `reason`/`detail` vars, not parsed
  # out of its English. Anything else is shown as written.
  defp field_message(message, opts) do
    case {opts[:reason], opts[:detail]} do
      {"missing", _} ->
        gettext("This is required.")

      {"invalid", detail} when is_binary(detail) ->
        {first, rest} = String.split_at(detail, 1)
        String.upcase(first) <> rest

      _ ->
        translate_error({message, opts})
    end
  end

  # The draft's config: a map once `coerce/2` has run on a change, the stored
  # map on an edit form, nothing yet on a fresh one.
  defp config_value(form) do
    case form[:config].value do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  attr :field, :map, required: true
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :errors, :list, default: []
  attr :options, :map, required: true

  defp config_field(%{field: %{meta: %{widget: :deliver_as}}} = assigns) do
    assigns = assign(assigns, :current, assigns.value || "email")

    ~H"""
    <fieldset id={@id}>
      <legend class="text-sm font-medium">{@field.meta.label}</legend>
      <div class="mt-1.5 grid gap-2 sm:grid-cols-3">
        <label
          :for={{value, label, hint} <- deliver_as_options()}
          class={[
            "flex cursor-pointer items-start gap-2 rounded-md border bg-base-100 p-3 transition-colors",
            "hover:border-base-content/30",
            @current == value && "border-primary ring-1 ring-primary",
            @current != value && "border-base-content/15"
          ]}
        >
          <input
            type="radio"
            name={@name}
            value={value}
            checked={@current == value}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@errors != [] && "#{@id}-error"}
            class="mt-0.5 accent-primary"
          />
          <span>
            <span class="block text-sm font-medium">{label}</span>
            <span class="block text-xs text-base-content/60">{hint}</span>
          </span>
        </label>
      </div>
      <div :if={@errors != []} id={"#{@id}-error"}>
        <.field_error :for={msg <- @errors} msg={msg} />
      </div>
    </fieldset>
    """
  end

  defp config_field(%{field: %{meta: %{widget: :toggle}}} = assigns) do
    ~H"""
    <div>
      <.input
        type="checkbox"
        id={@id}
        name={@name}
        label={@field.meta.label}
        checked={@value == true}
        errors={@errors}
      />
      <p :if={@field.meta[:hint]} class="-mt-1 ml-6 text-xs text-base-content/60">
        {@field.meta.hint}
      </p>
    </div>
    """
  end

  defp config_field(%{field: %{meta: %{widget: {:select, source}}}} = assigns) do
    assigns =
      assign(
        assigns,
        :select_options,
        with_stored_value(Map.get(assigns.options, source, []), assigns.value)
      )

    ~H"""
    <.input
      type="select"
      id={@id}
      name={@name}
      value={@value}
      label={@field.meta.label}
      prompt={@field.meta[:prompt]}
      options={@select_options}
      hint={@field.meta[:hint]}
      required={@field.required?}
      errors={@errors}
    />
    """
  end

  defp config_field(assigns) do
    assigns = assign(assigns, :type, input_type(assigns.field.meta.widget))

    ~H"""
    <%!-- A literal `phx-hook`: the `.InsertToken` shorthand is expanded to the
         colocated hook's full name only when it is written as a plain string,
         and an expression here left the browser looking up a hook that does not
         exist. On a field with no chips the hook finds nothing to click. --%>
    <div id={"#{@id}-wrap"} phx-hook=".InsertToken">
      <.input
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        label={@field.meta.label}
        placeholder={@field.meta[:placeholder]}
        hint={@field.meta[:hint]}
        required={@field.required?}
        errors={@errors}
        rows={@type == "textarea" && "3"}
        min={@type == "number" && "1"}
      />
      <div :if={@field.meta[:tokens]} class="-mt-1 flex flex-wrap items-center gap-1.5">
        <span class="text-xs text-base-content/60">{gettext("Insert:")}</span>
        <button
          :for={token <- tokens(@field.meta.tokens)}
          type="button"
          data-token={"{{#{token}}}"}
          aria-label={gettext("Insert the %{name} placeholder", name: token_label(token))}
          class="rounded-full border border-base-content/15 bg-base-100 px-2 py-0.5 text-xs text-base-content/80 transition-colors hover:border-primary hover:text-primary-ink"
        >
          {token_label(token)}
        </button>
      </div>
    </div>
    <script :type={ColocatedHook} name=".InsertToken">
      // A chip inserts its {{placeholder}} at the caret of the field it sits
      // under, then fires `input` so the form's phx-change sees the new value.
      export default {
        mounted() {
          this.el.addEventListener("click", (e) => {
            const chip = e.target.closest("[data-token]")
            const field = this.el.querySelector("input, textarea")
            if (!chip || !field) return
            const token = chip.dataset.token
            const start = field.selectionStart ?? field.value.length
            const end = field.selectionEnd ?? field.value.length
            field.value = field.value.slice(0, start) + token + field.value.slice(end)
            field.focus()
            field.setSelectionRange(start + token.length, start + token.length)
            field.dispatchEvent(new Event("input", {bubbles: true}))
          })
        },
      }
    </script>
    """
  end

  # A stored value the option list doesn't contain — a segment since deleted,
  # an assignee no longer an editor — is kept as an option of its own. A
  # select can't show a value it has no option for, so the browser would fall
  # to the prompt, and saving an unrelated edit would silently blank the key:
  # for `segment_id` that turns "one segment" (currently refused, a safe
  # failure) into "every confirmed subscriber".
  defp with_stored_value(options, value) when is_binary(value) and value != "" do
    if Enum.any?(options, fn {_label, option} -> to_string(option) == value end),
      do: options,
      else: [{gettext("Unavailable (%{value})", value: value), value} | options]
  end

  defp with_stored_value(options, _value), do: options

  attr :msg, :string, required: true

  defp field_error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {@msg}
    </p>
    """
  end

  defp input_type(:email), do: "email"
  defp input_type(:textarea), do: "textarea"
  defp input_type(:number), do: "number"
  defp input_type(_widget), do: "text"

  defp tokens(:content), do: RuleWorker.template_tokens()
  defp tokens(:social), do: Composer.template_tokens()

  # The values come from `ActionConfig.deliver_as_values/0`; only the wording
  # is here, with a plain fallback for a value added there first.
  defp deliver_as_options do
    for value <- ActionConfig.deliver_as_values() do
      {label, hint} = deliver_as_label(value)
      {value, label, hint}
    end
  end

  @doc false
  def deliver_as_label("email"), do: {gettext("Email"), gettext("Send a summary to an address")}

  def deliver_as_label("comment"),
    do: {gettext("Comment"), gettext("Leave a note on the content")}

  def deliver_as_label("task"), do: {gettext("Task"), gettext("Assign follow-up to a person")}
  def deliver_as_label(value), do: {Phoenix.Naming.humanize(value), nil}

  defp token_label("id"), do: gettext("ID")
  defp token_label("title"), do: gettext("Title")
  defp token_label("slug"), do: gettext("Slug")
  defp token_label("type"), do: gettext("Content type")
  defp token_label("event"), do: gettext("Event")
  defp token_label("excerpt"), do: gettext("Summary")
  defp token_label("url"), do: gettext("Link")
  defp token_label(token), do: token
end
