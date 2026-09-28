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
    params = prepare_params(params)
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("create", %{"rule" => params}, socket) when is_map(params) do
    case submit(socket.assigns.form, params, names(socket.assigns)) do
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
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, prepare_params(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"rule" => params}, socket) when is_map(params) do
    case submit(socket.assigns.edit.form, params, names(socket.assigns)) do
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

  defp submit(form, params, names) do
    params = params |> prepare_params() |> name_from_summary(names)
    AshPhoenix.Form.submit(form, params: params)
  end

  # The name is optional in the builder: left blank, the rule is named by the
  # sentence it reads as — the same one the form previewed as its placeholder.
  # Only on submit: filling it on a change would put the sentence into the
  # input, where it would stop following the trigger and action it describes.
  defp name_from_summary(params, names) do
    if blank?(params["name"]) do
      summary = Wording.summary(draft_from_params(params), names)
      Map.put(params, "name", String.slice(summary, 0, KilnCMS.Limits.line()))
    else
      params
    end
  end

  defp draft_from_params(params) do
    %{
      trigger_event: parse_trigger(params["trigger_event"]),
      content_type: params["content_type"],
      action: parse_action(params["action"]),
      config: params["config"]
    }
  end

  # The draft rule the form currently describes. An untouched form has no
  # trigger or action yet, while its controls already show the first of
  # each — so fall back to those, like `selected_action/1`.
  defp draft(form) do
    %{
      trigger_event: parse_trigger(form[:trigger_event].value) || List.first(Rule.triggers()),
      content_type: form[:content_type].value,
      action: selected_action(form),
      config: if(is_map(form[:config].value), do: form[:config].value, else: %{})
    }
  end

  # What `Wording.summary/2` needs to say a rule in an admin's words: content
  # type labels, and the people and segments the pickers offer.
  defp names(%{type_options: types, config_options: options}) do
    %{
      types: for({label, value} <- types, value != "", into: %{}, do: {value, label}),
      users: Map.new(Map.get(options, :users, []), fn {label, id} -> {id, label} end),
      segments: Map.new(Map.get(options, :segments, []), fn {label, id} -> {id, label} end)
    }
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # The settings inputs post strings under `rule[config]`; `ConfigFields.coerce/2`
  # makes them the typed map the selected action accepts. An action with no
  # settings (`reindex`, say) posts no config at all, which becomes `%{}`.
  defp prepare_params(params) do
    action = parse_action(params["action"])
    Map.put(params, "config", ConfigFields.coerce(action, params["config"] || %{}))
  end

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

  # An untouched form has no `action` value yet, while the select already shows
  # its first option — so fall back to that rather than describing a reaction
  # the admin isn't looking at.
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
    assigns = assign(assigns, :names, names(assigns))

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
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
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
            <.button type="submit" variant="primary">{gettext("Add rule")}</.button>
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
            <li :for={rule <- @rules} id={"rule-#{rule.id}"} class="p-4">
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
                  <p
                    :if={rule_summary(rule, @names) != rule.name}
                    class="text-sm text-base-content/70"
                  >
                    {rule_summary(rule, @names)}
                  </p>
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
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
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

  defp rule_summary(rule, names), do: Wording.summary(rule, names)

  attr :form, :any, required: true
  attr :type_options, :list, required: true
  attr :config_options, :map, required: true
  attr :names, :map, required: true

  # The builder as four numbered steps — when, do what, how, and what to call
  # it — ending on the sentence the rule will read as. The sentence is live:
  # every change re-renders it, so the admin reads back what they built before
  # saving it.
  defp rule_fields(assigns) do
    draft = draft(assigns.form)

    assigns =
      assigns
      |> assign(:selected_action, draft.action)
      |> assign(:summary, Wording.summary(draft, assigns.names))

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
      </.step>

      <.step number={2} title={gettext("Do this")}>
        <.action_cards form={@form} selected={@selected_action} />
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
          aria-live="polite"
          class="mb-3 flex items-start gap-3 rounded-lg border border-base-content/10 bg-base-200/50 p-3 text-sm"
        >
          <.icon name="hero-bolt" class="mt-0.5 size-4 shrink-0 text-base-content/60" />
          <p>{@summary}</p>
        </div>
        <.input
          field={@form[:name]}
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
