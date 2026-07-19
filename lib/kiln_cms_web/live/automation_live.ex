defmodule KilnCMSWeb.AutomationLive do
  @moduledoc """
  Editorial automation (`/editor/automation`) — a no-code "when X happens, do Y"
  builder over Kiln's Oban + state machine + PubSub/MTA (#342). Admin-only,
  mirroring the `Automation.Rule` policy. Each rule pairs a lifecycle trigger
  (optionally scoped to one content type) with a reaction.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Automation
  alias KilnCMS.Automation.Rule
  alias KilnCMS.CMS.ContentTypes

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
  def handle_event("validate", %{"rule" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("create", %{"rule" => params}, socket) do
    case submit(socket.assigns.form, params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_rules()
         |> put_flash(:info, gettext("Rule added."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}

      {:invalid_json, form} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> put_flash(:error, gettext("Action config must be valid JSON."))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"rule" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, params)
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"rule" => params}, socket) do
    case submit(socket.assigns.edit.form, params) do
      {:ok, _rule} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_rules() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}

      {:invalid_json, form} ->
        {:noreply,
         socket
         |> assign(:edit, %{socket.assigns.edit | form: form})
         |> put_flash(:error, gettext("Action config must be valid JSON."))}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
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

  def handle_event("delete", %{"id" => id}, socket) do
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
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "rule")
    |> to_form()
  end

  # The dynamic-type registry (`ContentTypes.*`) keys by a raw org_id.
  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id

  # `config` is entered as JSON in a textarea; decode it to a map before submit
  # (a :map attribute can't take the raw string). Invalid JSON surfaces its own
  # outcome so the caller can flash a friendly message.
  defp submit(form, params) do
    case decode_config(params) do
      {:ok, params} -> AshPhoenix.Form.submit(form, params: params)
      :error -> {:invalid_json, AshPhoenix.Form.validate(form, params)}
    end
  end

  defp decode_config(%{"config" => raw} = params) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:ok, Map.put(params, "config", %{})}

      match?({:ok, %{}}, Jason.decode(trimmed)) ->
        {:ok, Map.put(params, "config", Jason.decode!(trimmed))}

      true ->
        :error
    end
  end

  defp decode_config(params), do: {:ok, params}

  defp type_options(org) do
    types = ContentTypes.all() ++ ContentTypes.dynamic_all(org_id(org))
    [{gettext("Any content type"), ""}] ++ Enum.map(types, &{&1.label, to_string(&1.type)})
  end

  defp trigger_options, do: Enum.map(Rule.triggers(), &{Phoenix.Naming.humanize(&1), &1})
  defp action_options, do: Enum.map(Rule.action_kinds(), &{Phoenix.Naming.humanize(&1), &1})

  defp config_json(form) do
    case form[:config].value do
      map when is_map(map) and map_size(map) > 0 -> Jason.encode!(map, pretty: true)
      raw when is_binary(raw) -> raw
      _ -> ""
    end
  end

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
            <.rule_fields form={@form} type_options={@type_options} />
            <.button type="submit" variant="primary">{gettext("Add rule")}</.button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Rules")} ({length(@rules)})</h2>

          <p :if={@rules == []} class="text-sm text-base-content/60">
            {gettext("No automation rules yet.")}
          </p>

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
                <.rule_fields form={@edit.form} type_options={@type_options} />
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

  defp rule_fields(assigns) do
    assigns =
      assigns
      |> assign(:trigger_options, trigger_options())
      |> assign(:action_options, action_options())
      |> assign(:config_json, config_json(assigns.form))

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
    <div>
      <label class="text-sm font-medium" for={@form[:config].id}>
        {gettext("Action config (JSON)")}
      </label>
      <textarea
        id={@form[:config].id}
        name={@form[:config].name}
        rows="3"
        class="mt-1 w-full rounded border border-base-content/20 bg-base-100 p-2 font-mono text-xs"
        placeholder={~s({"to": "team@example.com", "subject": "Live: {{title}}"})}
      >{@config_json}</textarea>
      <p class="mt-1 text-xs text-base-content/60">
        {gettext(
          "send_email: to, subject, body. broadcast: topic. Templates support {{title}}, {{slug}}, {{type}}, {{event}}."
        )}
      </p>
    </div>
    """
  end
end
