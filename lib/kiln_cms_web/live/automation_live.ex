defmodule KilnCMSWeb.AutomationLive do
  @moduledoc """
  Editorial automation (`/editor/automation`) — a no-code "when X happens, do Y"
  builder over Kiln's Oban + state machine + PubSub/MTA (#342). Admin-only,
  mirroring the `Automation.Rule` policy. Each rule pairs a lifecycle trigger
  (optionally scoped to one content type) with a reaction, configured through
  generated inputs rather than JSON (`KilnCMSWeb.AutomationLive.ConfigFields`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Automation
  alias KilnCMS.Automation.Rule
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Newsletter
  alias KilnCMS.Social.Account
  alias KilnCMSWeb.AutomationLive.ConfigFields
  alias KilnCMSWeb.AutomationLive.Wording
  alias KilnCMSWeb.ContentEditor.Shared

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Automation"))
       |> assign(:type_options, type_options(org))
       |> assign(:config_options, config_options(socket, actor, org))
       |> assign_names()
       |> assign(:edit, nil)
       |> assign(:form, create_form(actor, org))
       |> load_rules()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("validate", %{"rule" => params}, socket) when is_map(params) do
    params = prepare_params(params, socket.assigns.names)
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("create", %{"rule" => params}, socket) when is_map(params) do
    case submit(socket.assigns.form, params, socket.assigns.names) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_rules()
         |> put_flash(:info, gettext("Rule added."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"rule" => params}, socket) when is_map(params) do
    edit = %{
      socket.assigns.edit
      | form:
          AshPhoenix.Form.validate(
            socket.assigns.edit.form,
            prepare_params(params, socket.assigns.names)
          )
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"rule" => params}, socket) when is_map(params) do
    case submit(socket.assigns.edit.form, params, socket.assigns.names) do
      {:ok, _rule} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_rules() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, rule} <- Automation.get_rule(id, actor: actor, tenant: org),
           {:ok, _} <-
             Automation.update_rule(rule, %{enabled: !rule.enabled}, actor: actor, tenant: org) do
        load_rules(socket)
      else
        _ -> put_flash(socket, :error, gettext("Couldn't update that rule."))
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor

    org = socket.assigns.current_org

    socket =
      with {:ok, rule} <- Automation.get_rule(id, actor: actor, tenant: org),
           :ok <- Automation.destroy_rule(rule, actor: actor, tenant: org) do
        socket |> load_rules() |> put_flash(:info, gettext("Rule deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that rule."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- data ------------------------------------------------------------------

  defp load_rules(socket) do
    assign(
      socket,
      :rules,
      Automation.list_rules!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [inserted_at: :asc]]
      )
    )
  end

  defp create_form(actor, org),
    do:
      Rule
      |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: "rule")
      |> to_form()

  defp edit_form(id, actor, org) do
    Automation.get_rule!(id, actor: actor, tenant: org)
    # Its own `id` (inputs keep the shared `rule[...]` names): the add-rule
    # form is on the page at the same time, and both defaulting to "rule"
    # gave every field in the two forms the same DOM id.
    |> AshPhoenix.Form.for_update(:update,
      actor: actor,
      tenant: org,
      as: "rule",
      id: "rule_#{id}"
    )
    |> to_form()
  end

  defp submit(form, params, names),
    do: AshPhoenix.Form.submit(form, params: prepare_params(params, names))

  # The settings inputs post strings under `rule[config]`; `ConfigFields.coerce/2`
  # makes them the typed map the selected action accepts. An action with no
  # settings (`reindex`, say) posts no config at all, which becomes `%{}`.
  #
  # The name is optional in the builder: left blank, the rule is named by the
  # sentence it reads as (`Wording.default_name/2`). The fill runs on every
  # change as well as on submit, so a blank name is never flagged "required";
  # and the name field renders blank whenever its value is that sentence
  # (`name_value/2`), so a failed save or an edit never freezes the sentence
  # into the input — it keeps following the trigger and action it describes.
  defp prepare_params(params, names) do
    action = parse_action(params["action"])
    params = Map.put(params, "config", ConfigFields.coerce(action, params["config"] || %{}))

    if blank?(params["name"]),
      do: Map.put(params, "name", Wording.default_name(draft_from_params(params), names)),
      else: params
  end

  # The same draft `draft/1` reads off a form, read off posted params.
  defp draft_from_params(params) do
    %{
      trigger_event: parse_trigger(params["trigger_event"]) || Wording.default_trigger(),
      content_type: params["content_type"],
      action: parse_action(params["action"]) || List.first(Rule.action_kinds()),
      config: params["config"]
    }
  end

  # The draft rule the form currently describes. An untouched form has no
  # trigger or action yet, while its controls already show a choice — the
  # event select its first option, the cards the one `selected_action/1`
  # checks — so fall back to those.
  defp draft(form) do
    %{
      trigger_event: parse_trigger(form[:trigger_event].value) || Wording.default_trigger(),
      content_type: form[:content_type].value,
      action: selected_action(form),
      config: if(is_map(form[:config].value), do: form[:config].value, else: %{})
    }
  end

  # What `Wording.summary/2` needs to say a rule in an admin's words: content
  # type labels, and the people, segments and networks the pickers offer.
  # Both inputs are set once in `mount/3`, so this is too — built in
  # `render/1` it would count as changed on every render and re-send the whole
  # rules list on each keystroke. `segments` stays `nil` until the pickers
  # load (the disconnected render), which `Wording` reads as "can't tell"
  # rather than "no such segment".
  defp assign_names(%{assigns: %{type_options: types, config_options: options}} = socket) do
    assign(socket, :names, %{
      types: for({label, value} <- types, value != "", into: %{}, do: {value, label}),
      users: label_map(options[:users]),
      segments: options[:segments] && label_map(options[:segments]),
      providers: label_map(options[:providers])
    })
  end

  defp label_map(nil), do: %{}
  defp label_map(options), do: Map.new(options, fn {label, value} -> {value, label} end)

  # The name field's value: blank when the form's name is just the sentence
  # the rule reads as, so the placeholder shows it and it keeps following.
  defp name_value(form, default_name) do
    case form[:name].value do
      ^default_name -> ""
      value -> value
    end
  end

  # Each rule with the sentence it reads as, or `nil` when its name already
  # is that sentence (so the list doesn't say it twice). Only re-run when
  # `@rules` changes — `@names` is fixed after mount.
  defp rule_rows(rules, names) do
    for rule <- rules do
      sentence = Wording.summary(rule, names)
      same? = rule.name == String.slice(sentence, 0, KilnCMS.Limits.line())
      {rule, if(same?, do: nil, else: sentence)}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # Option lists for the settings form's pickers — the same assignee roster the
  # content editor's task picker offers (`Shared.assignable_users/1`). Loaded on
  # the connected mount only: the static render is replaced as soon as the
  # socket joins, and a picker's options are not worth two more queries per
  # page load. Until then the pickers show their prompt alone.
  defp config_options(socket, actor, org) do
    if connected?(socket), do: load_config_options(actor, org), else: %{}
  end

  defp load_config_options(actor, org) do
    %{
      users: Shared.assignable_users(org),
      segments: Enum.map(Newsletter.list_segments!(actor: actor, tenant: org), &{&1.name, &1.id}),
      providers: Enum.map(Account.providers(), &{Phoenix.Naming.humanize(&1), to_string(&1)})
    }
  end

  # Editorial tasks (#501) aren't a content type — `task.assigned` /
  # `task.overdue` are task-domain events dispatched through the same
  # `<type>.<verb>` funnel with a literal "task" type (see
  # `KilnCMS.Automation.Rule`'s `@triggers` moduledoc note). Without the trailing
  # entry, a rule triggered on `:assigned`/`:overdue` could only be left at "Any
  # content type" (matches every event, not just task ones) or pointed at an
  # existing content type — which `Rule.matching`'s exact-match filter then never
  # fires for: a silently dead rule.
  defp type_options(org) do
    ContentTypes.options(org, prompt: {gettext("Any content type"), ""}) ++
      [{gettext("Tasks"), "task"}]
  end

  # An untouched form has no `action` value yet; the cards check this one, so
  # the sentence describes the reaction the admin is looking at.
  defp selected_action(form),
    do: parse_action(form[:action].value) || List.first(Rule.action_kinds())

  defp parse_action(value), do: parse_one_of(Rule.action_kinds(), value)
  defp parse_trigger(value), do: parse_one_of(Rule.triggers(), value)

  defp parse_one_of(_known, nil), do: nil
  defp parse_one_of(known, value), do: Enum.find(known, &(to_string(&1) == to_string(value)))

  defp editing?(nil, _id), do: false
  defp editing?(%{id: id}, id), do: true
  defp editing?(_edit, _id), do: false

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:automation}
    >
      <div class="space-y-8">
        <div>
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:automation}
          />
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Automation")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Run a reaction when content is published, updated, or unpublished — email, an internal broadcast, cache invalidation, or a re-index. HTTP/Slack notifications are the Webhooks page's job."
            )}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Add a rule")}</h2>
          <.form
            for={@form}
            id="new-rule-form"
            phx-change="validate"
            phx-submit="create"
            class="card card-pad space-y-4"
          >
            <.rule_fields
              form={@form}
              type_options={@type_options}
              config_options={@config_options}
              names={@names}
            />
            <.button type="submit" variant="primary" aria-describedby="rule_summary">
              {gettext("Add rule")}
            </.button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Rules")} ({length(@rules)})</h2>

          <.empty_state
            :if={@rules == []}
            icon="hero-cpu-chip"
            title={gettext("No automation rules yet")}
          >
            {gettext("Add a rule above to run actions when content events fire.")}
          </.empty_state>

          <ul :if={@rules != []} class="card divide-y divide-base-content/10 overflow-hidden">
            <li
              :for={{rule, sentence} <- rule_rows(@rules, @names)}
              id={"rule-#{rule.id}"}
              class="p-4"
            >
              <div :if={!editing?(@edit, rule.id)} class="flex items-start justify-between gap-4">
                <div class="min-w-0 space-y-1">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "inline-block size-2 shrink-0 rounded-full",
                      rule.enabled && "bg-success",
                      !rule.enabled && "bg-base-content/30"
                    ]} />
                    <span class="font-medium">{rule.name}</span>
                  </div>
                  <p :if={sentence} class="text-sm text-base-content/70">{sentence}</p>
                  <p :if={rule.description} class="text-xs text-base-content/60">
                    {rule.description}
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="toggle_enabled"
                    phx-value-id={rule.id}
                    class="btn btn-sm btn-default"
                  >
                    {if rule.enabled, do: gettext("Disable"), else: gettext("Enable")}
                  </button>
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-id={rule.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Edit")}
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={rule.id}
                    data-confirm={gettext("Delete this rule?")}
                    aria-label={gettext("Delete rule")}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>

              <.form
                :if={editing?(@edit, rule.id)}
                for={@edit.form}
                id={"edit-rule-#{rule.id}"}
                phx-change="validate_edit"
                phx-submit="save_edit"
                class="space-y-4"
              >
                <.rule_fields
                  form={@edit.form}
                  type_options={@type_options}
                  config_options={@config_options}
                  names={@names}
                />
                <label class="flex items-center gap-2 text-sm">
                  <input type="hidden" name="rule[enabled]" value="false" />
                  <input
                    type="checkbox"
                    name="rule[enabled]"
                    value="true"
                    checked={@edit.form[:enabled].value in [true, "true"]}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                  />
                  {gettext("Enabled")}
                </label>
                <div class="flex gap-2">
                  <.button
                    type="submit"
                    variant="primary"
                    aria-describedby={"#{@edit.form.id}_summary"}
                  >
                    {gettext("Save")}
                  </.button>
                  <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-default">
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :form, :any, required: true
  attr :type_options, :list, required: true
  attr :config_options, :map, required: true
  attr :names, :map, required: true

  # The builder as four numbered steps — when, do what, how, and what to call
  # it — ending on the sentence the rule will read as. The sentence follows
  # every change, so the admin reads back what they built before saving it.
  # It is not an `aria-live` region — it would re-announce on every keystroke
  # of "Send to" — but the submit button's description, read at the moment
  # it matters.
  defp rule_fields(assigns) do
    draft = draft(assigns.form)
    summary = Wording.summary(draft, assigns.names)

    assigns =
      assigns
      |> assign(:selected_action, draft.action)
      |> assign(:summary, summary)
      |> assign(:name_value, name_value(assigns.form, Wording.default_name(draft, assigns.names)))
      |> assign(:dead_scope?, Wording.dead_scope?(draft.trigger_event, draft.content_type))

    ~H"""
    <ol class="space-y-6">
      <.step number={1} title={gettext("When this happens")}>
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:content_type]}
            type="select"
            label={gettext("Content")}
            options={@type_options}
          />
          <.input
            field={@form[:trigger_event]}
            type="select"
            label={gettext("Event")}
            options={Wording.trigger_options()}
          />
        </div>
        <p
          :if={@dead_scope?}
          id={"#{@form.id}_scope_warning"}
          class="flex items-start gap-2 text-sm text-warning-ink"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          {gettext(
            "This rule would never run: only tasks are assigned or go overdue, and tasks are never published or updated. Pick “Tasks” for a task event, or a content type for the others."
          )}
        </p>
      </.step>

      <.step number={2} title={gettext("Do this")}>
        <.action_cards form={@form} selected={@selected_action} />
        <%!-- The cards replaced a select that showed these; a refused value
             (a tampered post, a reaction removed mid-session) says why. --%>
        <div :if={@form[:action].errors != []} id={"#{@form.id}_action-error"}>
          <p
            :for={msg <- Enum.map(@form[:action].errors, &translate_error/1)}
            class="flex items-center gap-2 text-sm text-error"
          >
            <.icon name="hero-exclamation-circle" class="size-5" />
            {msg}
          </p>
        </div>
      </.step>

      <.step number={3} title={gettext("Set it up")}>
        <ConfigFields.config_fields
          form={@form}
          action={@selected_action}
          options={@config_options}
        />
      </.step>

      <.step number={4} title={gettext("Name it")}>
        <div
          id={"#{@form.id}_summary"}
          class="mb-3 flex items-start gap-3 rounded-lg border border-base-content/10 bg-base-200/50 p-3 text-sm"
        >
          <.icon name="hero-bolt" class="mt-0.5 size-4 shrink-0 text-base-content/60" />
          <p>{@summary}</p>
        </div>
        <.input
          field={@form[:name]}
          value={@name_value}
          label={gettext("Name")}
          placeholder={@summary}
          hint={gettext("Optional. Left blank, the rule is named by the sentence above.")}
        />
        <.input
          field={@form[:description]}
          label={gettext("Description")}
          placeholder={gettext("Optional")}
        />
      </.step>
    </ol>
    """
  end

  attr :number, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <li class="flex gap-3">
      <span
        aria-hidden="true"
        class="flex size-6 shrink-0 items-center justify-center rounded-full bg-base-content text-xs font-semibold text-base-100"
      >
        {@number}
      </span>
      <div class="min-w-0 flex-1 space-y-3">
        <h3 class="text-sm font-semibold leading-6">{@title}</h3>
        {render_slot(@inner_block)}
      </div>
    </li>
    """
  end

  attr :form, :any, required: true
  attr :selected, :atom, required: true

  # The reaction picker: a radio group drawn as cards, grouped by purpose, so an
  # admin chooses "Send the newsletter" by reading what it does rather than by
  # recognising `newsletter` in a list of atoms.
  defp action_cards(assigns) do
    ~H"""
    <fieldset class="space-y-4">
      <legend class="sr-only">{gettext("Do this")}</legend>
      <div :for={{group, cards} <- Wording.action_groups()} class="space-y-2">
        <p class="text-xs font-medium text-base-content/60">{group}</p>
        <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
          <label
            :for={{action, card} <- cards}
            for={"#{@form.id}_action_#{action}"}
            class={[
              "flex cursor-pointer items-start gap-3 rounded-lg border bg-base-100 p-3 transition-colors",
              "hover:border-base-content/30 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary",
              @selected == action && "border-primary ring-1 ring-primary",
              @selected != action && "border-base-content/15"
            ]}
          >
            <input
              type="radio"
              id={"#{@form.id}_action_#{action}"}
              name={@form[:action].name}
              value={action}
              checked={@selected == action}
              class="sr-only"
            />
            <span class={[
              "flex size-8 shrink-0 items-center justify-center rounded-md transition-colors",
              @selected == action && "bg-primary text-primary-content",
              @selected != action && "bg-base-200 text-base-content/70"
            ]}>
              <.icon name={card.icon} class="size-4" />
            </span>
            <span class="min-w-0">
              <span class="block text-sm font-medium">{card.label}</span>
              <span :if={card.description} class="block text-xs text-base-content/60">
                {card.description}
              </span>
            </span>
          </label>
        </div>
      </div>
    </fieldset>
    """
  end
end
