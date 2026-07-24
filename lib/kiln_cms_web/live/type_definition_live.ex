defmodule KilnCMSWeb.TypeDefinitionLive do
  @moduledoc """
  Content types (`/editor/types`) — admin-defined **dynamic content types**
  (decision D17, `docs/dynamic-content-types-plan.md`). An admin names a type
  ("Recipe"), and its schema is then built from custom fields on
  `/editor/fields`. Admin-only, mirroring the `TypeDefinition` policy.

  Types are archived, never hard-deleted: an archived type stops resolving but
  its entries and field definitions survive, and it can be restored here.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:edit, nil)
     |> assign(:form, create_form(actor, org))
     |> load_definitions()}
  end

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"type_definition" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("create", %{"type_definition" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _definition} ->
        {:noreply,
         socket
         |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
         |> load_definitions()
         |> put_flash(:info, gettext("Content type created. Now add its fields."))}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  # --- inline edit -------------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"type_definition" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, params)
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"type_definition" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: params) do
      {:ok, _definition} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_definitions() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  # --- archive / restore -------------------------------------------------------

  def handle_event("archive", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, definition} <- CMS.get_type_definition(id, actor: actor, tenant: org),
           :ok <- CMS.destroy_type_definition(definition, actor: actor, tenant: org) do
        socket |> load_definitions() |> put_flash(:info, gettext("Content type archived."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't archive that content type."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  def handle_event("restore", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, definition} <- get_archived(id, actor, org),
           {:ok, _} <- CMS.restore_type_definition(definition, actor: actor, tenant: org) do
        socket |> load_definitions() |> put_flash(:info, gettext("Content type restored."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't restore that content type."))
      end

    {:noreply, socket}
  end

  # --- data --------------------------------------------------------------------

  defp load_definitions(socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket
    |> assign(
      :definitions,
      CMS.list_type_definitions!(actor: actor, tenant: org, load: [:field_definitions])
    )
    |> assign(:archived, CMS.list_archived_type_definitions!(actor: actor, tenant: org))
  end

  # The default reads exclude archived rows (AshArchival), so restore has to
  # find its record through the `:archived` read.
  defp get_archived(id, actor, org) do
    case Enum.find(
           CMS.list_archived_type_definitions!(actor: actor, tenant: org),
           &(&1.id == id)
         ) do
      nil -> :error
      definition -> {:ok, definition}
    end
  end

  defp create_form(actor, org),
    do:
      KilnCMS.CMS.TypeDefinition
      |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: "type_definition")
      |> to_form()

  defp edit_form(id, actor, org) do
    CMS.get_type_definition!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "type_definition")
    |> to_form()
  end

  defp editing?(nil, _id), do: false
  defp editing?(%{id: id}, id), do: true
  defp editing?(_edit, _id), do: false

  # --- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={gettext("Content types")}
      active={:types}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Content types")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Define a new content type without a code change, then add its fields under Custom fields. Built-in types (pages, posts) are defined in code and don't appear here."
            )}
          </p>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("New content type")}</h2>
          <.form
            for={@form}
            id="new-type-form"
            phx-change="validate"
            phx-submit="create"
            class="card card-pad grid gap-4 sm:grid-cols-2"
          >
            <.input field={@form[:label]} label={gettext("Name")} placeholder="Recipe" />
            <.input
              field={@form[:plural_label]}
              label={gettext("Plural name")}
              placeholder="Recipes"
            />
            <.input
              field={@form[:name]}
              label={gettext("Machine name")}
              placeholder="recipe"
            />
            <.input
              field={@form[:path_segment]}
              label={gettext("URL segment (defaults to machine name + \"s\")")}
              placeholder="recipes"
            />
            <div class="sm:col-span-2">
              <.input field={@form[:description]} label={gettext("Description")} />
            </div>
            <div class="sm:col-span-2">
              <.input
                field={@form[:slug_pattern]}
                label={gettext("Slug pattern (optional)")}
                placeholder="[yyyy]-[mm]-[title]"
              />
              <p class="mt-1 text-xs text-base-content/60">
                {gettext(
                  "Tokens: %{tokens}. Composes the last URL segment; blank = derive from the SEO keyphrase or title.",
                  tokens: Enum.map_join(KilnCMS.Slug.Pattern.tokens(), ", ", &"[#{&1}]")
                )}
              </p>
            </div>
            <.input
              field={@form[:schema_org_type]}
              type="select"
              label={gettext("schema.org type (structured data)")}
              options={KilnCMS.Firing.SchemaOrg.types()}
            />
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="type_definition[has_excerpt]" value="false" />
              <input
                type="checkbox"
                name="type_definition[has_excerpt]"
                value="true"
                checked={@form[:has_excerpt].value in [true, "true"]}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Has an excerpt (for listings and feeds)")}
            </label>
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="type_definition[has_published_feed]" value="false" />
              <input
                type="checkbox"
                name="type_definition[has_published_feed]"
                value="true"
                checked={@form[:has_published_feed].value in [true, "true"]}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Has a public index of published entries")}
            </label>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Create content type")}</.button>
            </div>
          </.form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Defined types")}</h2>

          <p :if={@definitions == []} class="text-sm text-base-content/60">
            {gettext("No custom content types yet.")}
          </p>

          <ul
            :if={@definitions != []}
            class="card divide-y divide-base-content/10 overflow-hidden"
          >
            <li :for={definition <- @definitions} id={"type-#{definition.id}"} class="p-4">
              <div
                :if={!editing?(@edit, definition.id)}
                class="flex items-start justify-between gap-4"
              >
                <div class="min-w-0 space-y-1">
                  <div class="flex items-center gap-2">
                    <span class="font-medium">{definition.label}</span>
                    <code class="text-xs text-base-content/60">{definition.name}</code>
                    <span class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70">
                      /{definition.path_segment}
                    </span>
                  </div>
                  <p :if={definition.description} class="text-xs text-base-content/60">
                    {definition.description}
                  </p>
                  <p class="text-xs text-base-content/60">
                    {ngettext(
                      "%{count} field",
                      "%{count} fields",
                      length(definition.field_definitions)
                    )} &middot;
                    <.link navigate={~p"/editor/fields"} class="hover:underline">
                      {gettext("Manage fields")}
                    </.link>
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-id={definition.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Edit")}
                  </button>
                  <button
                    type="button"
                    phx-click="archive"
                    phx-value-id={definition.id}
                    data-confirm={
                      gettext(
                        "Archive this content type? Its entries stop being served but are kept, and you can restore it later."
                      )
                    }
                    aria-label={gettext("Archive content type")}
                    class="btn btn-sm btn-ghost hover:text-error"
                  >
                    <.icon name="hero-archive-box" class="size-4" />
                  </button>
                </div>
              </div>

              <.form
                :if={editing?(@edit, definition.id)}
                for={@edit.form}
                id={"edit-type-#{definition.id}"}
                phx-change="validate_edit"
                phx-submit="save_edit"
                class="grid gap-4 sm:grid-cols-2"
              >
                <.input field={@edit.form[:label]} label={gettext("Name")} />
                <.input field={@edit.form[:plural_label]} label={gettext("Plural name")} />
                <.input field={@edit.form[:path_segment]} label={gettext("URL segment")} />
                <.input field={@edit.form[:description]} label={gettext("Description")} />
                <.input
                  field={@edit.form[:slug_pattern]}
                  label={gettext("Slug pattern (optional)")}
                  placeholder="[yyyy]-[mm]-[title]"
                />
                <.input
                  field={@edit.form[:schema_org_type]}
                  type="select"
                  label={gettext("schema.org type")}
                  options={KilnCMS.Firing.SchemaOrg.types()}
                />
                <label class="flex items-center gap-2 text-sm">
                  <input type="hidden" name="type_definition[has_excerpt]" value="false" />
                  <input
                    type="checkbox"
                    name="type_definition[has_excerpt]"
                    value="true"
                    checked={@edit.form[:has_excerpt].value in [true, "true"]}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                  />
                  {gettext("Has an excerpt")}
                </label>
                <label class="flex items-center gap-2 text-sm">
                  <input type="hidden" name="type_definition[has_published_feed]" value="false" />
                  <input
                    type="checkbox"
                    name="type_definition[has_published_feed]"
                    value="true"
                    checked={@edit.form[:has_published_feed].value in [true, "true"]}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                  />
                  {gettext("Has a public index")}
                </label>
                <div class="flex gap-2 sm:col-span-2">
                  <.button type="submit" variant="primary">{gettext("Save")}</.button>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    class="btn btn-default"
                  >
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            </li>
          </ul>
        </section>

        <section :if={@archived != []} class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Archived types")}</h2>
          <ul class="card divide-y divide-base-content/10 overflow-hidden">
            <li
              :for={definition <- @archived}
              id={"archived-type-#{definition.id}"}
              class="flex items-center justify-between gap-4 p-4"
            >
              <div class="flex items-center gap-2">
                <span class="font-medium text-base-content/70">{definition.label}</span>
                <code class="text-xs text-base-content/50">{definition.name}</code>
              </div>
              <button
                type="button"
                phx-click="restore"
                phx-value-id={definition.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Restore")}
              </button>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
