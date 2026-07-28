defmodule KilnCMSWeb.TaxonomyLive do
  @moduledoc """
  Taxonomy management — create, rename, and (admin) delete the `Category`,
  `TagGroup`, and `Tag` lists that content is organized by. Editors and admins
  only (`:live_editor_required`); deletes are admin-only, mirroring the resource
  policies.

  Tags are listed **under their group**, which is also how the content editor's
  picker renders them — see `KilnCMS.CMS.TagGroup`.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Tag
  alias KilnCMS.CMS.TagGroup

  @loads [:page_count, :post_count]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:admin?, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> assign(:page_title, gettext("Taxonomy"))
     |> assign(:edit, nil)
     |> assign(:content_type_options, content_type_options(org))
     |> assign(:cat_form, create_form(:category, actor, org))
     |> assign(:group_form, create_form(:tag_group, actor, org))
     |> assign(:tag_form, create_form(:tag, actor, org))
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
         |> assign(
           :cat_form,
           create_form(:category, socket.assigns.actor, socket.assigns.current_org)
         )
         |> load_taxonomy()
         |> put_flash(:info, gettext("Category added."))}

      {:error, form} ->
        {:noreply, assign(socket, :cat_form, form)}
    end
  end

  def handle_event("validate_group", %{"tag_group" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.group_form, normalize_types(params))
    {:noreply, assign(socket, :group_form, form)}
  end

  def handle_event("create_group", %{"tag_group" => params}, socket) do
    params = params |> with_slug() |> normalize_types()

    case AshPhoenix.Form.submit(socket.assigns.group_form, params: params) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> assign(
           :group_form,
           create_form(:tag_group, socket.assigns.actor, socket.assigns.current_org)
         )
         |> load_taxonomy()
         |> put_flash(:info, gettext("Tag group added."))}

      {:error, form} ->
        {:noreply, assign(socket, :group_form, form)}
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
         |> assign(:tag_form, create_form(:tag, socket.assigns.actor, socket.assigns.current_org))
         |> load_taxonomy()
         |> put_flash(:info, gettext("Tag added."))}

      {:error, form} ->
        {:noreply, assign(socket, :tag_form, form)}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"type" => type, "id" => id}, socket) do
    form = edit_form(type, id, socket.assigns.actor, socket.assigns.current_org)
    {:noreply, assign(socket, :edit, %{type: type, id: id, form: form})}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"taxonomy" => params}, socket) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize_types(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"taxonomy" => params}, socket) do
    params = params |> with_slug() |> normalize_types()

    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: params) do
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
      case destroy(type, id, socket.assigns.actor, socket.assigns.current_org) do
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
    org = socket.assigns.current_org

    # `TagGroup`'s primary read is already ordered by position then name.
    groups = CMS.list_tag_groups!(actor: actor, tenant: org, load: [:tag_count])

    tags =
      CMS.list_tags!(actor: actor, tenant: org, load: @loads, query: sort_by_name())

    socket
    |> assign(
      :categories,
      CMS.list_categories!(actor: actor, tenant: org, load: @loads, query: sort_by_name())
    )
    |> assign(:groups, groups)
    |> assign(:tags, tags)
    |> assign(:grouped_tags, group_tags(tags, groups))
  end

  defp sort_by_name, do: [sort: [name: :asc]]

  # Tags bucketed by group, in picker order, with "Ungrouped" last. Every group
  # is listed even when empty so editors can see a bucket they've yet to fill;
  # "Ungrouped" only appears when it has something in it.
  defp group_tags(tags, groups) do
    by_group = Enum.group_by(tags, & &1.tag_group_id)
    named = Enum.map(groups, &{&1.id, &1.name, Map.get(by_group, &1.id, [])})

    case Map.get(by_group, nil, []) do
      [] -> named
      loose -> named ++ [{nil, gettext("Ungrouped"), loose}]
    end
  end

  # Every content type a tag group can be scoped to — compiled and admin-defined
  # alike, addressed by the public type-name string (`ContentTypes.type_name/1`'s
  # currency). Same enumeration the editor and field-definition admin use.
  defp content_type_options(org) do
    (ContentTypes.all() ++ ContentTypes.dynamic_all(org_id(org)))
    |> Enum.map(&{&1.label, to_string(&1.type)})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id

  # Distinct form names keep input ids unique across the create forms (and the
  # inline edit form) on the same page. `tenant:` stamps the new row's org so
  # taxonomy is created into the current site (epic #336).
  defp create_form(:category, actor, org),
    do:
      AshPhoenix.Form.for_create(Category, :create, actor: actor, tenant: org, as: "category")
      |> to_form()

  defp create_form(:tag_group, actor, org),
    do:
      AshPhoenix.Form.for_create(TagGroup, :create, actor: actor, tenant: org, as: "tag_group")
      |> to_form()

  defp create_form(:tag, actor, org),
    do:
      AshPhoenix.Form.for_create(Tag, :create, actor: actor, tenant: org, as: "tag")
      |> to_form()

  defp edit_form("category", id, actor, org) do
    CMS.get_category!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "taxonomy")
    |> to_form()
  end

  defp edit_form("tag_group", id, actor, org) do
    CMS.get_tag_group!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "taxonomy")
    |> to_form()
  end

  defp edit_form("tag", id, actor, org) do
    CMS.get_tag!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "taxonomy")
    |> to_form()
  end

  defp destroy("category", id, actor, org) do
    with {:ok, record} <- CMS.get_category(id, actor: actor, tenant: org),
         do: CMS.destroy_category(record, actor: actor, tenant: org)
  end

  defp destroy("tag_group", id, actor, org) do
    with {:ok, record} <- CMS.get_tag_group(id, actor: actor, tenant: org),
         do: CMS.destroy_tag_group(record, actor: actor, tenant: org)
  end

  defp destroy("tag", id, actor, org) do
    with {:ok, record} <- CMS.get_tag(id, actor: actor, tenant: org),
         do: CMS.destroy_tag(record, actor: actor, tenant: org)
  end

  # Fill a blank slug from the name so editors only have to type a label. An
  # explicit slug always wins.
  defp with_slug(params) do
    name = Map.get(params, "name", "")

    case String.trim(Map.get(params, "slug", "")) do
      "" -> Map.put(params, "slug", KilnCMS.Slug.slugify(name))
      _slug -> params
    end
  end

  # The content-type checkboxes are preceded by a hidden empty input so that
  # unchecking every box still submits the key (browsers omit an all-unchecked
  # checkbox group entirely, which would leave the old scope in place instead of
  # clearing it). Drop that sentinel before it reaches the changeset — `[]` is
  # what "applies to every type" is stored as.
  defp normalize_types(%{"content_types" => types} = params) when is_list(types),
    do: Map.put(params, "content_types", Enum.reject(types, &(&1 == "")))

  defp normalize_types(params), do: params

  defp editing?(nil, _type, _id), do: false
  defp editing?(%{type: t, id: i}, type, id), do: t == type and i == id

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:taxonomy}
    >
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
            admin?={@admin?}
            with_description={true}
            groups={@groups}
            content_type_options={@content_type_options}
          />
          <.taxonomy_column
            kind="tag_group"
            heading={gettext("Tag groups")}
            blurb={
              gettext(
                "Buckets that tags are filed under, so the editor's tag picker stays scannable."
              )
            }
            form={@group_form}
            validate="validate_group"
            submit="create_group"
            records={@groups}
            edit={@edit}
            admin?={@admin?}
            with_description={true}
            groups={@groups}
            content_type_options={@content_type_options}
          />
        </div>

        <.taxonomy_column
          kind="tag"
          heading={gettext("Tags")}
          blurb={gettext("Content can carry any number of tags.")}
          form={@tag_form}
          validate="validate_tag"
          submit="create_tag"
          records={@tags}
          grouped={@grouped_tags}
          edit={@edit}
          admin?={@admin?}
          with_description={false}
          groups={@groups}
          content_type_options={@content_type_options}
        />
      </div>
    </Layouts.console>
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
  attr :admin?, :boolean, required: true
  attr :with_description, :boolean, required: true
  attr :groups, :list, required: true
  attr :content_type_options, :list, required: true
  # `nil` renders one flat list; otherwise `{key, label, records}` sections.
  attr :grouped, :any, default: nil

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
        class="card card-pad space-y-3"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:name]}
            label={gettext("Name")}
            placeholder={gettext("New %{kind} name", kind: kind_label(@kind))}
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
        <.extra_fields
          kind={@kind}
          form={@form}
          groups={@groups}
          content_type_options={@content_type_options}
        />
        <.button type="submit" variant="primary">
          {gettext("Add %{kind}", kind: kind_label(@kind))}
        </.button>
      </.form>

      <p :if={@records == []} class="text-sm text-base-content/60">
        {none_yet(@kind)}
      </p>

      <ul :if={@records != [] and is_nil(@grouped)} class="card divide-y divide-base-content/10">
        <.taxonomy_row
          :for={record <- @records}
          record={record}
          kind={@kind}
          edit={@edit}
          admin?={@admin?}
          with_description={@with_description}
          groups={@groups}
          content_type_options={@content_type_options}
        />
      </ul>

      <div :if={@records != [] and not is_nil(@grouped)} class="space-y-4">
        <section :for={{_key, label, records} <- @grouped} class="space-y-1">
          <h3 class="text-sm font-semibold text-base-content/70">
            {label} <span class="font-normal text-base-content/50">({length(records)})</span>
          </h3>
          <p :if={records == []} class="text-xs text-base-content/50">
            {gettext("No tags in this group yet.")}
          </p>
          <ul :if={records != []} class="card divide-y divide-base-content/10">
            <.taxonomy_row
              :for={record <- records}
              record={record}
              kind={@kind}
              edit={@edit}
              admin?={@admin?}
              with_description={@with_description}
              groups={@groups}
              content_type_options={@content_type_options}
            />
          </ul>
        </section>
      </div>
    </section>
    """
  end

  attr :record, :any, required: true
  attr :kind, :string, required: true
  attr :edit, :any, required: true
  attr :admin?, :boolean, required: true
  attr :with_description, :boolean, required: true
  attr :groups, :list, required: true
  attr :content_type_options, :list, required: true

  defp taxonomy_row(assigns) do
    assigns = assign(assigns, :scope, scope_line(assigns.record))

    ~H"""
    <li class="p-3">
      <div :if={!editing?(@edit, @kind, @record.id)} class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="truncate font-medium">{@record.name}</p>
          <p class="truncate text-xs text-base-content/70">
            <code>{@record.slug}</code> · {usage_line(@record)}
          </p>
          <p :if={@scope} class="truncate text-xs text-base-content/50">{@scope}</p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            phx-click="edit"
            phx-value-type={@kind}
            phx-value-id={@record.id}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Edit")}
          </button>
          <button
            :if={@admin?}
            type="button"
            phx-click="delete"
            phx-value-type={@kind}
            phx-value-id={@record.id}
            data-confirm={delete_confirm(@record)}
            aria-label={gettext("Delete %{name}", name: @record.name)}
            class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>

      <.form
        :if={editing?(@edit, @kind, @record.id)}
        for={@edit.form}
        id={"edit-#{@kind}-#{@record.id}"}
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
        <.extra_fields
          kind={@kind}
          form={@edit.form}
          groups={@groups}
          content_type_options={@content_type_options}
        />
        <div class="flex gap-2">
          <.button type="submit" variant="primary">{gettext("Save")}</.button>
          <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-default">
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
    </li>
    """
  end

  # Per-kind form fields beyond the shared name/slug/description trio.
  attr :kind, :string, required: true
  attr :form, :any, required: true
  attr :groups, :list, required: true
  attr :content_type_options, :list, required: true

  defp extra_fields(%{kind: "tag_group"} = assigns) do
    assigns = assign(assigns, :selected, selected_types(assigns.form))

    ~H"""
    <.input
      field={@form[:position]}
      type="number"
      label={gettext("Position")}
      value={@form[:position].value || 0}
    />

    <fieldset>
      <legend class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Content types")}
      </legend>
      <p class="mb-2 text-xs text-base-content/60">
        {gettext("Leave all unchecked to offer this group on every content type.")}
      </p>
      <%!-- Sentinel so an all-unchecked group still submits the key and clears
            the scope; stripped by `normalize_types/1`. --%>
      <input type="hidden" name={@form[:content_types].name <> "[]"} value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={{label, value} <- @content_type_options}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded border border-base-content/20 px-2 py-1 text-sm hover:bg-base-200"
        >
          <input
            type="checkbox"
            name={@form[:content_types].name <> "[]"}
            value={value}
            checked={value in @selected}
            class="size-4 rounded border border-base-content/30 accent-primary"
          />
          {label}
        </label>
      </div>
    </fieldset>
    """
  end

  defp extra_fields(%{kind: "tag"} = assigns) do
    ~H"""
    <.input
      field={@form[:tag_group_id]}
      type="select"
      label={gettext("Group")}
      prompt={gettext("— Ungrouped —")}
      options={Enum.map(@groups, &{&1.name, &1.id})}
    />
    """
  end

  defp extra_fields(assigns) do
    ~H"""
    """
  end

  # Currently-checked content types: the in-progress form value once touched,
  # otherwise whatever is stored. Always strings, to compare against the option
  # values.
  defp selected_types(form) do
    case form[:content_types].value do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  # The "· N pages, N posts" (or "· N tags") line under a record's slug.
  defp usage_line(%TagGroup{} = group),
    do: ngettext("%{count} tag", "%{count} tags", group.tag_count, count: group.tag_count)

  defp usage_line(record) do
    pages =
      ngettext("%{count} page", "%{count} pages", record.page_count, count: record.page_count)

    posts =
      ngettext("%{count} post", "%{count} posts", record.post_count, count: record.post_count)

    "#{pages}, #{posts}"
  end

  # Only tag groups carry a content-type scope; nil hides the line entirely.
  defp scope_line(%TagGroup{content_types: []}), do: gettext("All content types")

  defp scope_line(%TagGroup{content_types: types}),
    do: gettext("Only: %{types}", types: Enum.join(types, ", "))

  defp scope_line(_record), do: nil

  defp delete_confirm(%TagGroup{tag_count: 0} = group),
    do: gettext("Delete “%{name}”?", name: group.name)

  defp delete_confirm(%TagGroup{} = group) do
    gettext(
      "“%{name}” holds %{count} tag(s). Delete the group anyway? The tags are kept and become ungrouped.",
      name: group.name,
      count: group.tag_count
    )
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

  # Whole translatable sentences instead of interpolating a naively
  # pluralized English noun ("No categorys yet.").
  defp none_yet("category"), do: gettext("No categories yet.")
  defp none_yet("tag_group"), do: gettext("No tag groups yet.")
  defp none_yet("tag"), do: gettext("No tags yet.")
  defp none_yet(_kind), do: gettext("Nothing here yet.")

  # The translated noun for interpolations like "Add %{kind}" — the raw kind
  # string would surface untranslated English ("Ajouter category").
  defp kind_label("category"), do: gettext("category")
  defp kind_label("tag_group"), do: gettext("tag group")
  defp kind_label("tag"), do: gettext("tag")
  defp kind_label(kind), do: kind
end
