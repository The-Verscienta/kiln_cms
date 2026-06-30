defmodule KilnCMSWeb.FieldDefinitionLive do
  @moduledoc """
  Custom fields (`/editor/fields`) — the admin-UI-first half of the schema. An
  admin defines typed custom fields per content type (the Directus "add a field
  in the UI" workflow, within decision D4); the content editor then renders an
  input per definition and `Changes.ApplyCustomFields` coerces/validates the
  values into each record's `custom_fields` map. Admin-only, mirroring the
  `FieldDefinition` policy.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:content_types, ContentTypes.all())
       |> assign(:field_types, FieldDefinition.field_types())
       |> assign(:edit, nil)
       |> assign(:form, create_form(actor))
       |> load_definitions()}
    else
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # redirects non-admins before mount; mirror its flash here for consistency.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"field_definition" => params}, socket) do
    {:noreply,
     assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, normalize(params)))}
  end

  def handle_event("create", %{"field_definition" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: normalize(params)) do
      {:ok, _definition} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor))
         |> load_definitions()
         |> put_flash(:info, gettext("Field added."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :edit, %{id: id, form: edit_form(id, socket.assigns.actor)})}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"field_definition" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"field_definition" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: normalize(params)) do
      {:ok, _definition} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_definitions() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      with {:ok, definition} <- CMS.get_field_definition(id, actor: actor),
           :ok <- CMS.destroy_field_definition(definition, actor: actor) do
        socket |> load_definitions() |> put_flash(:info, gettext("Field deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that field."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- data ------------------------------------------------------------------

  defp load_definitions(socket) do
    definitions =
      CMS.list_field_definitions!(
        actor: socket.assigns.actor,
        query: [sort: [content_type: :asc, position: :asc, name: :asc]]
      )

    assign(socket, :grouped, Enum.group_by(definitions, & &1.content_type))
  end

  defp create_form(actor),
    do:
      FieldDefinition
      |> AshPhoenix.Form.for_create(:create, actor: actor, as: "field_definition")
      |> to_form()

  defp edit_form(id, actor) do
    CMS.get_field_definition!(id, actor: actor)
    |> AshPhoenix.Form.for_update(:update, actor: actor, as: "field_definition")
    |> to_form()
  end

  # Options are entered one-per-line (or comma-separated) in a textarea and
  # stored as a string array. Split, trim and drop blanks before they reach the
  # attribute. Only meaningful for `:select`, harmless otherwise.
  defp normalize(params) do
    options =
      params
      |> Map.get("options", "")
      |> to_string()
      |> String.split(["\n", ","], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "options", options)
  end

  # Textarea value for the options field: the stored list joined by newlines.
  defp options_text(form) do
    case form[:options].value do
      list when is_list(list) -> Enum.join(list, "\n")
      str when is_binary(str) -> str
      _ -> ""
    end
  end

  defp type_label(type), do: Phoenix.Naming.humanize(type)

  defp content_type_label(type) do
    case ContentTypes.get(type) do
      %{label: label} -> label
      _ -> Phoenix.Naming.humanize(type)
    end
  end

  defp editing?(nil, _id), do: false
  defp editing?(%{id: id}, id), do: true
  defp editing?(_edit, _id), do: false

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Custom fields")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Add typed fields to a content type without a code change. Editors fill them in the content editor; values are validated against these definitions."
            )}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Add a field")}</h2>
          <.form
            for={@form}
            id="new-field-form"
            phx-change="validate"
            phx-submit="create"
            class="grid gap-4 rounded-lg border border-base-content/15 p-4 sm:grid-cols-2"
          >
            <.input
              field={@form[:content_type]}
              type="select"
              label={gettext("Content type")}
              options={Enum.map(@content_types, &{&1.label, &1.type})}
            />
            <.input
              field={@form[:field_type]}
              type="select"
              label={gettext("Field type")}
              options={Enum.map(@field_types, &{type_label(&1), &1})}
            />
            <.input field={@form[:label]} label={gettext("Label")} placeholder="Toxicity level" />
            <.input
              field={@form[:name]}
              label={gettext("Machine name")}
              placeholder="toxicity_level"
            />
            <.input field={@form[:help_text]} label={gettext("Help text")} />
            <.input field={@form[:position]} type="number" label={gettext("Position")} />
            <div class="sm:col-span-2">
              <label class="mb-1 block text-sm font-medium">
                {gettext("Options (one per line — select only)")}
              </label>
              <textarea
                name="field_definition[options]"
                rows="3"
                class="w-full rounded border border-base-content/20 bg-base-100 px-3 py-2 text-sm"
              >{options_text(@form)}</textarea>
            </div>
            <.input field={@form[:default]} label={gettext("Default value")} />
            <label class="flex items-center gap-2 self-end text-sm">
              <input type="hidden" name="field_definition[required]" value="false" />
              <input
                type="checkbox"
                name="field_definition[required]"
                value="true"
                checked={@form[:required].value in [true, "true"]}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Required")}
            </label>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Add field")}</.button>
            </div>
          </.form>
        </section>

        <section class="space-y-6">
          <h2 class="text-lg font-medium">{gettext("Defined fields")}</h2>

          <p :if={@grouped == %{}} class="text-sm text-base-content/60">
            {gettext("No custom fields yet.")}
          </p>

          <div :for={{type, definitions} <- @grouped} class="space-y-3">
            <h3 class="text-sm font-semibold text-base-content/80">
              {content_type_label(type)}
            </h3>
            <ul class="divide-y divide-base-content/10 rounded-lg border border-base-content/15">
              <li :for={definition <- definitions} id={"field-#{definition.id}"} class="p-4">
                <div
                  :if={!editing?(@edit, definition.id)}
                  class="flex items-start justify-between gap-4"
                >
                  <div class="min-w-0 space-y-1">
                    <div class="flex items-center gap-2">
                      <span class="font-medium">{definition.label}</span>
                      <code class="text-xs text-base-content/60">{definition.name}</code>
                      <span class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70">
                        {type_label(definition.field_type)}
                      </span>
                      <span
                        :if={definition.required}
                        class="rounded bg-warning/20 px-1.5 py-0.5 text-xs text-warning"
                      >
                        {gettext("required")}
                      </span>
                    </div>
                    <p :if={definition.help_text} class="text-xs text-base-content/60">
                      {definition.help_text}
                    </p>
                    <p
                      :if={definition.field_type == :select and definition.options != []}
                      class="text-xs text-base-content/60"
                    >
                      {gettext("Options")}: {Enum.join(definition.options, ", ")}
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-1">
                    <button
                      type="button"
                      phx-click="edit"
                      phx-value-id={definition.id}
                      class="rounded px-2 py-1 text-xs hover:bg-base-200"
                    >
                      {gettext("Edit")}
                    </button>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={definition.id}
                      data-confirm={
                        gettext("Delete this field? Existing values stop being delivered.")
                      }
                      aria-label={gettext("Delete field")}
                      class="rounded px-2 py-1 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </div>

                <.form
                  :if={editing?(@edit, definition.id)}
                  for={@edit.form}
                  id={"edit-field-#{definition.id}"}
                  phx-change="validate_edit"
                  phx-submit="save_edit"
                  class="grid gap-4 sm:grid-cols-2"
                >
                  <.input
                    field={@edit.form[:field_type]}
                    type="select"
                    label={gettext("Field type")}
                    options={Enum.map(@field_types, &{type_label(&1), &1})}
                  />
                  <.input field={@edit.form[:label]} label={gettext("Label")} />
                  <.input field={@edit.form[:help_text]} label={gettext("Help text")} />
                  <.input field={@edit.form[:position]} type="number" label={gettext("Position")} />
                  <div class="sm:col-span-2">
                    <label class="mb-1 block text-sm font-medium">
                      {gettext("Options (one per line — select only)")}
                    </label>
                    <textarea
                      name="field_definition[options]"
                      rows="3"
                      class="w-full rounded border border-base-content/20 bg-base-100 px-3 py-2 text-sm"
                    >{options_text(@edit.form)}</textarea>
                  </div>
                  <.input field={@edit.form[:default]} label={gettext("Default value")} />
                  <label class="flex items-center gap-2 self-end text-sm">
                    <input type="hidden" name="field_definition[required]" value="false" />
                    <input
                      type="checkbox"
                      name="field_definition[required]"
                      value="true"
                      checked={@edit.form[:required].value in [true, "true"]}
                      class="size-4 rounded border border-base-content/30 accent-primary"
                    />
                    {gettext("Required")}
                  </label>
                  <div class="flex gap-2 sm:col-span-2">
                    <.button type="submit" variant="primary">{gettext("Save")}</.button>
                    <button
                      type="button"
                      phx-click="cancel_edit"
                      class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200"
                    >
                      {gettext("Cancel")}
                    </button>
                  </div>
                </.form>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
