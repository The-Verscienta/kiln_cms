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
  alias KilnCMSWeb.AutomationLive.Preview
  alias KilnCMSWeb.AutomationLive.Recipes
  alias KilnCMSWeb.AutomationLive.Wording
  alias KilnCMSWeb.ContentEditor.Shared

  # The "Try it" panel: `options` is nil until the admin opens it (listing
  # documents is a read per content type, not worth making on every visit);
  # `loaded` caches the picked document so a keystroke doesn't re-read it.
  # `scope` is the content type the options were listed for — `:unset` until
  # the first listing, since `nil` is a real scope ("any content").
  @no_preview %{options: nil, scope: :unset, value: nil, loaded: nil, effects: nil}

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
       |> assign(:recipe, nil)
       |> assign(:preview, @no_preview)
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
  def handle_event("validate", %{"rule" => params} = all, socket) when is_map(params) do
    params = prepare_params(params, socket.assigns.names)

    {:noreply,
     socket
     |> assign(:form, AshPhoenix.Form.validate(socket.assigns.form, params))
     |> refresh_preview(:create, all["preview_record"])}
  end

  # `target` says which builder's panel was opened: the add form's, or the
  # edit form's — each has its own, since both can be on the page at once.
  def handle_event("open_preview", %{"target" => target}, socket)
      when target in ["create", "edit"] do
    target = String.to_existing_atom(target)

    {:noreply,
     socket
     |> put_preview(target, %{@no_preview | options: []})
     |> refresh_preview(target, nil)}
  end

  def handle_event("create", %{"rule" => params}, socket) when is_map(params) do
    case submit(socket.assigns.form, params, socket.assigns.names) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> assign(:recipe, nil)
         |> assign(:preview, @no_preview)
         |> load_rules()
         |> put_flash(:info, gettext("Rule added."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  # A recipe fills a fresh builder; it saves nothing. The settings a recipe
  # leaves for the admin to choose (which network, which segment) aren't
  # flagged red: `ConfigFields` holds its errors until the first save attempt,
  # and a filled builder hasn't had one.
  def handle_event("use_recipe", %{"id" => id}, socket) when is_binary(id) do
    case Recipes.get(id, recipe_context(socket.assigns)) do
      nil ->
        {:noreply, socket}

      recipe ->
        form =
          socket.assigns.actor
          |> create_form(socket.assigns.current_org)
          |> AshPhoenix.Form.validate(prepare_params(recipe.params, socket.assigns.names))

        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:recipe, recipe)
         |> refresh_preview(:create, socket.assigns.preview.value)}
    end
  end

  def handle_event("clear_recipe", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
     |> assign(:recipe, nil)
     |> refresh_preview(:create, socket.assigns.preview.value)}
  end

  def handle_event("edit", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org),
       preview: @no_preview
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"rule" => params} = all, socket) when is_map(params) do
    edit = %{
      socket.assigns.edit
      | form:
          AshPhoenix.Form.validate(
            socket.assigns.edit.form,
            prepare_params(params, socket.assigns.names)
          )
    }

    {:noreply,
     socket
     |> assign(:edit, edit)
     |> refresh_preview(:edit, all["preview_record"])}
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

  # Re-lists the documents when the rule's content-type scope changes, re-reads
  # the picked one only when the pick changes, and recomputes the effects from
  # the draft every time — the preview follows the rule as it is edited.
  defp refresh_preview(socket, target, value) do
    case builder(socket, target) do
      {_form, %{options: nil}} -> socket
      {form, preview} -> put_preview(socket, target, refreshed(socket, form, preview, value))
    end
  end

  defp refreshed(socket, form, preview, value) do
    %{actor: actor, current_org: org} = socket.assigns
    draft = draft(form)
    scope = draft.content_type

    preview =
      if preview.scope == scope,
        do: preview,
        else: %{preview | options: Preview.candidates(actor, org, scope), scope: scope}

    value = if value in [nil, ""], do: nil, else: value

    loaded =
      cond do
        is_nil(value) -> nil
        value == preview.value -> preview.loaded
        true -> Preview.load(value, actor, org)
      end

    effects =
      with {type, record} <- loaded,
           true <- Preview.previewable?(draft.trigger_event) do
        Preview.run(draft, type, record, org)
      else
        _ -> nil
      end

    %{preview | value: value, loaded: loaded, effects: effects}
  end

  # The form and "Try it" state of one builder: the add form's live at the top
  # level, an open edit form's inside `@edit`.
  defp builder(socket, :create), do: {socket.assigns.form, socket.assigns.preview}
  defp builder(%{assigns: %{edit: %{form: form, preview: preview}}}, :edit), do: {form, preview}
  defp builder(_socket, :edit), do: {nil, %{options: nil}}

  defp put_preview(socket, :create, preview), do: assign(socket, :preview, preview)

  defp put_preview(%{assigns: %{edit: %{} = edit}} = socket, :edit, preview),
    do: assign(socket, :edit, %{edit | preview: preview})

  defp put_preview(socket, :edit, _preview), do: socket

  defp recipe_context(%{current_user: user, type_options: types}) do
    %{
      email: user.email && to_string(user.email),
      types: for({_label, value} <- types, value != "", do: value)
    }
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

        <.recipes recipes={Recipes.all(recipe_context(assigns))} open={@rules == []} />

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Add a rule")}</h2>
          <.form
            for={@form}
            id="new-rule-form"
            phx-change="validate"
            phx-submit="create"
            class="card card-pad space-y-4"
          >
            <div
              :if={@recipe}
              id="recipe-banner"
              class="flex items-center justify-between gap-3 rounded-lg border border-primary/30 bg-primary/5 px-3 py-2 text-sm"
            >
              <span>
                {gettext("Started from “%{recipe}”. Change anything you like, then add the rule.",
                  recipe: @recipe.title
                )}
              </span>
              <button type="button" phx-click="clear_recipe" class="btn btn-sm btn-ghost shrink-0">
                {gettext("Start over")}
              </button>
            </div>
            <.rule_fields
              form={@form}
              type_options={@type_options}
              config_options={@config_options}
              names={@names}
              preview={@preview}
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
                  preview={@edit.preview}
                  preview_target="edit"
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

  attr :recipes, :list, required: true
  attr :open, :boolean, required: true

  # The gallery of ready-made rules. Open while the site has no rules — the
  # moment a starting point helps most — and folded away once it has some,
  # still one click from reach.
  defp recipes(assigns) do
    ~H"""
    <%!-- `open` is only re-sent when `@open` itself changes (the site's first
         rule folds it), so an admin's own open/fold survives the re-renders
         in between — picking a recipe included. --%>
    <details id="recipes" class="group space-y-3" open={@open}>
      <summary class="flex cursor-pointer list-none items-center gap-2 text-lg font-medium">
        <.icon
          name="hero-chevron-right"
          class="size-4 text-base-content/60 transition-transform group-open:rotate-90"
        />
        {gettext("Start from a recipe")}
      </summary>
      <p class="text-sm text-base-content/70">
        {gettext("Pick one to fill in the form below — nothing is saved until you add the rule.")}
      </p>
      <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
        <button
          :for={recipe <- @recipes}
          type="button"
          id={"recipe-#{recipe.id}"}
          phx-click="use_recipe"
          phx-value-id={recipe.id}
          class="flex items-start gap-3 rounded-lg border border-base-content/15 bg-base-100 p-3 text-left transition-colors hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
        >
          <span class="flex size-8 shrink-0 items-center justify-center rounded-md bg-base-200 text-base-content/70">
            <.icon name={recipe.icon} class="size-4" />
          </span>
          <span class="min-w-0">
            <span class="block text-sm font-medium">{recipe.title}</span>
            <span class="block text-xs text-base-content/60">{recipe.description}</span>
          </span>
        </button>
      </div>
    </details>
    """
  end

  attr :form, :any, required: true
  attr :type_options, :list, required: true
  attr :config_options, :map, required: true
  attr :names, :map, required: true
  attr :preview, :map, default: nil, doc: "the builder's \"Try it\" state"
  attr :preview_target, :string, default: "create", doc: "which builder: create or edit"

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
      |> assign(:draft, draft)
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

      <.step :if={@preview} number={5} title={gettext("Try it (optional)")}>
        <.try_it
          form={@form}
          target={@preview_target}
          preview={@preview}
          draft={@draft}
          names={@names}
        />
      </.step>
    </ol>
    """
  end

  attr :form, :any, required: true
  attr :target, :string, required: true
  attr :preview, :map, required: true
  attr :draft, :map, required: true
  attr :names, :map, required: true

  # Pick a real document and see what the rule would do to it. The picker is
  # in the builder form under its own name (`preview_record`, not `rule[…]`),
  # so a pick arrives with the form's own change event and nothing about it
  # is ever submitted as part of the rule.
  defp try_it(assigns) do
    ~H"""
    <%!-- Ids from the form's own: the add form and an edit form can both be
         on the page, each with a panel. --%>
    <div
      id={"#{@form.id}_try_it"}
      class="space-y-3 rounded-lg border border-dashed border-base-content/20 p-3"
    >
      <div :if={is_nil(@preview.options)} class="flex flex-wrap items-center gap-3">
        <button
          type="button"
          phx-click="open_preview"
          phx-value-target={@target}
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-eye" class="size-4" /> {gettext("Try it on real content")}
        </button>
        <span class="text-xs text-base-content/60">
          {gettext("See what this rule would do. Nothing is sent or saved.")}
        </span>
      </div>

      <div :if={@preview.options} class="space-y-3">
        <p :if={not Preview.previewable?(@draft.trigger_event)} class="text-sm text-base-content/70">
          {gettext("Task events can't be tried on a piece of content.")}
        </p>

        <div :if={Preview.previewable?(@draft.trigger_event)}>
          <p :if={@preview.options == []} class="text-sm text-base-content/70">
            {gettext("There's no content of this type to try it on yet.")}
          </p>
          <.input
            :if={@preview.options != []}
            type="select"
            id={"#{@form.id}_preview_record"}
            name="preview_record"
            value={@preview.value}
            label={gettext("Try it on")}
            prompt={gettext("Choose a piece of content")}
            options={@preview.options}
          />
          <%!-- Not `aria-live`, for the reason the rule's sentence isn't: it
               re-renders on every keystroke in the builder, and a live region
               would read the whole preview out each time. --%>
          <div
            :if={@preview.effects}
            id={"#{@form.id}_preview_effects"}
            class="rounded-md bg-base-200/40 p-3"
          >
            <p class="mb-2 text-xs font-medium text-base-content/60">
              {gettext("This rule would:")}
            </p>
            <Preview.effects effects={@preview.effects} names={@names} />
          </div>
          <p class="mt-2 text-xs text-base-content/60">
            {gettext("A preview. Nothing is sent, posted or saved.")}
          </p>
        </div>
      </div>
    </div>
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
