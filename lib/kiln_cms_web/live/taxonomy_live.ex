defmodule KilnCMSWeb.TaxonomyLive do
  @moduledoc """
  Taxonomy management — create, rename, and (admin) delete the `Category` and
  `Tag` lists that content is organized by. Editors and admins only
  (`:live_editor_required`); deletes are admin-only, mirroring the resource
  policies.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.Tag

  @loads [:page_count, :post_count]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:edit, nil)
     |> assign(:cat_form, create_form(:category, actor))
     |> assign(:tag_form, create_form(:tag, actor))
     |> load_taxonomy()}
  end

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate_cat", %{"category" => params}, socket) do
    {:noreply,
     assign(socket, :cat_form, AshPhoenix.Form.validate(socket.assigns.cat_form, params))}
  end

  def handle_event("create_cat", %{"category" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.cat_form, params: with_slug(params)) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> assign(:cat_form, create_form(:category, socket.assigns.actor))
         |> load_taxonomy()
         |> put_flash(:info, gettext("Category added."))}

      {:error, form} ->
        {:noreply, assign(socket, :cat_form, form)}
    end
  end

  def handle_event("validate_tag", %{"tag" => params}, socket) do
    {:noreply,
     assign(socket, :tag_form, AshPhoenix.Form.validate(socket.assigns.tag_form, params))}
  end

  def handle_event("create_tag", %{"tag" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.tag_form, params: with_slug(params)) do
      {:ok, _tag} ->
        {:noreply,
         socket
         |> assign(:tag_form, create_form(:tag, socket.assigns.actor))
         |> load_taxonomy()
         |> put_flash(:info, gettext("Tag added."))}

      {:error, form} ->
        {:noreply, assign(socket, :tag_form, form)}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"type" => type, "id" => id}, socket) do
    form = edit_form(type, id, socket.assigns.actor)
    {:noreply, assign(socket, :edit, %{type: type, id: id, form: form})}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"taxonomy" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, params)
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"taxonomy" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: with_slug(params)) do
      {:ok, _record} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_taxonomy() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
    end
  end

  # --- delete (admin only) ---------------------------------------------------

  def handle_event("delete", %{"type" => type, "id" => id}, socket) do
    socket =
      case destroy(type, id, socket.assigns.actor) do
        :ok ->
          socket |> load_taxonomy() |> put_flash(:info, gettext("Deleted."))

        _ ->
          put_flash(
            socket,
            :error,
            gettext("Couldn't delete that — you may not have permission.")
          )
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- data ------------------------------------------------------------------

  defp load_taxonomy(socket) do
    actor = socket.assigns.actor

    socket
    |> assign(
      :categories,
      CMS.list_categories!(actor: actor, load: @loads, query: sort_by_name())
    )
    |> assign(:tags, CMS.list_tags!(actor: actor, load: @loads, query: sort_by_name()))
  end

  defp sort_by_name, do: [sort: [name: :asc]]

  # Distinct form names keep input ids unique across the two create forms (and
  # the inline edit form) on the same page.
  defp create_form(:category, actor),
    do: AshPhoenix.Form.for_create(Category, :create, actor: actor, as: "category") |> to_form()

  defp create_form(:tag, actor),
    do: AshPhoenix.Form.for_create(Tag, :create, actor: actor, as: "tag") |> to_form()

  defp edit_form("category", id, actor) do
    CMS.get_category!(id, actor: actor)
    |> AshPhoenix.Form.for_update(:update, actor: actor, as: "taxonomy")
    |> to_form()
  end

  defp edit_form("tag", id, actor) do
    CMS.get_tag!(id, actor: actor)
    |> AshPhoenix.Form.for_update(:update, actor: actor, as: "taxonomy")
    |> to_form()
  end

  defp destroy("category", id, actor) do
    with {:ok, record} <- CMS.get_category(id, actor: actor),
         do: CMS.destroy_category(record, actor: actor)
  end

  defp destroy("tag", id, actor) do
    with {:ok, record} <- CMS.get_tag(id, actor: actor),
         do: CMS.destroy_tag(record, actor: actor)
  end

  # Fill a blank slug from the name so editors only have to type a label. An
  # explicit slug always wins.
  defp with_slug(params) do
    name = Map.get(params, "name", "")

    case String.trim(Map.get(params, "slug", "")) do
      "" -> Map.put(params, "slug", slugify(name))
      _slug -> params
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s_-]+/, "-")
    |> String.trim("-")
  end

  defp editing?(nil, _type, _id), do: false
  defp editing?(%{type: t, id: i}, type, id), do: t == type and i == id

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Taxonomy")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("Manage the categories and tags content can be organized by.")}
          </p>
        </div>

        <div class="grid gap-8 lg:grid-cols-2">
          <.taxonomy_column
            kind="category"
            heading={gettext("Categories")}
            blurb={gettext("A piece of content belongs to one category.")}
            form={@cat_form}
            validate="validate_cat"
            submit="create_cat"
            records={@categories}
            edit={@edit}
            actor={@actor}
            with_description={true}
          />
          <.taxonomy_column
            kind="tag"
            heading={gettext("Tags")}
            blurb={gettext("Content can carry any number of tags.")}
            form={@tag_form}
            validate="validate_tag"
            submit="create_tag"
            records={@tags}
            edit={@edit}
            actor={@actor}
            with_description={false}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :kind, :string, required: true
  attr :heading, :string, required: true
  attr :blurb, :string, required: true
  attr :form, :any, required: true
  attr :validate, :string, required: true
  attr :submit, :string, required: true
  attr :records, :list, required: true
  attr :edit, :any, required: true
  attr :actor, :map, required: true
  attr :with_description, :boolean, required: true

  defp taxonomy_column(assigns) do
    ~H"""
    <section class="space-y-4">
      <div>
        <h2 class="text-lg font-medium">{@heading} ({length(@records)})</h2>
        <p class="text-sm text-base-content/60">{@blurb}</p>
      </div>

      <.form
        for={@form}
        id={"new-#{@kind}-form"}
        phx-change={@validate}
        phx-submit={@submit}
        class="space-y-3 rounded-lg border border-base-content/15 p-4"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:name]}
            label={gettext("Name")}
            placeholder={gettext("New %{kind} name", kind: @kind)}
          />
          <.input
            field={@form[:slug]}
            label={gettext("Slug")}
            placeholder={gettext("Auto from name")}
          />
        </div>
        <.input
          :if={@with_description}
          field={@form[:description]}
          type="textarea"
          label={gettext("Description")}
        />
        <.button type="submit" variant="primary">{gettext("Add %{kind}", kind: @kind)}</.button>
      </.form>

      <p :if={@records == []} class="text-sm text-base-content/60">
        {gettext("No %{kind}s yet.", kind: @kind)}
      </p>

      <ul
        :if={@records != []}
        class="divide-y divide-base-content/10 rounded-lg border border-base-content/15"
      >
        <li :for={record <- @records} class="p-3">
          <div :if={!editing?(@edit, @kind, record.id)} class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate font-medium">{record.name}</p>
              <p class="truncate text-xs text-base-content/50">
                <code>{record.slug}</code>
                · {record.page_count} {pluralize(record.page_count, "page")}, {record.post_count} {pluralize(
                  record.post_count,
                  "post"
                )}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <button
                type="button"
                phx-click="edit"
                phx-value-type={@kind}
                phx-value-id={record.id}
                class="rounded px-2 py-1 text-xs hover:bg-base-200"
              >
                {gettext("Edit")}
              </button>
              <button
                :if={@actor.role == :admin}
                type="button"
                phx-click="delete"
                phx-value-type={@kind}
                phx-value-id={record.id}
                data-confirm={delete_confirm(record)}
                aria-label={gettext("Delete %{name}", name: record.name)}
                class="rounded px-2 py-1 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>

          <.form
            :if={editing?(@edit, @kind, record.id)}
            for={@edit.form}
            id={"edit-#{@kind}-#{record.id}"}
            phx-change="validate_edit"
            phx-submit="save_edit"
            class="space-y-3"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <.input field={@edit.form[:name]} label={gettext("Name")} />
              <.input field={@edit.form[:slug]} label={gettext("Slug")} />
            </div>
            <.input
              :if={@with_description}
              field={@edit.form[:description]}
              type="textarea"
              label={gettext("Description")}
            />
            <div class="flex gap-2">
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
    </section>
    """
  end

  defp delete_confirm(record) do
    case record.page_count + record.post_count do
      0 ->
        gettext("Delete “%{name}”?", name: record.name)

      n ->
        gettext(
          "“%{name}” is used by %{count} item(s). Delete it anyway? The links will be removed.",
          name: record.name,
          count: n
        )
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
