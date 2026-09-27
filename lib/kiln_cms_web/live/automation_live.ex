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
    case submit(socket.assigns.form, params) do
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
    case submit(socket.assigns.edit.form, params) do
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

  defp submit(form, params), do: AshPhoenix.Form.submit(form, params: prepare_params(params))

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

  defp trigger_options, do: Enum.map(Rule.triggers(), &{Phoenix.Naming.humanize(&1), &1})
  defp action_options, do: Enum.map(Rule.action_kinds(), &{Phoenix.Naming.humanize(&1), &1})

  # An untouched form has no `action` value yet, while the select already shows
  # its first option — so fall back to that rather than describing a reaction
  # the admin isn't looking at.
  defp selected_action(form),
    do: parse_action(form[:action].value) || List.first(Rule.action_kinds())

  defp parse_action(nil), do: nil

  defp parse_action(value),
    do: Enum.find(Rule.action_kinds(), &(to_string(&1) == to_string(value)))

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
            <.rule_fields form={@form} type_options={@type_options} config_options={@config_options} />
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
                  <p class="text-sm text-base-content/70">
                    {gettext("When")}
                    <code class="text-xs">{rule.content_type || "*"}.{rule.trigger_event}</code>
                    &rarr; <code class="text-xs">{rule.action}</code>
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

  attr :form, :any, required: true
  attr :type_options, :list, required: true
  attr :config_options, :map, required: true

  defp rule_fields(assigns) do
    assigns =
      assigns
      |> assign(:trigger_options, trigger_options())
      |> assign(:action_options, action_options())
      |> assign(:selected_action, selected_action(assigns.form))

    ~H"""
    <.input field={@form[:name]} label={gettext("Name")} placeholder="Notify on publish" />
    <div class="grid gap-4 sm:grid-cols-3">
      <.input
        field={@form[:trigger_event]}
        type="select"
        label={gettext("When")}
        options={@trigger_options}
      />
      <.input
        field={@form[:content_type]}
        type="select"
        label={gettext("Content type")}
        options={@type_options}
      />
      <.input
        field={@form[:action]}
        type="select"
        label={gettext("Do")}
        options={@action_options}
      />
    </div>
    <.input
      field={@form[:description]}
      label={gettext("Description")}
      placeholder={gettext("Optional")}
    />
    <ConfigFields.config_fields form={@form} action={@selected_action} options={@config_options} />
    """
  end
end
