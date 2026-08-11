defmodule KilnCMSWeb.TaxonomyLive do
  @moduledoc """
  Taxonomy management — create, rename, and (admin) delete the `Category`,
  `TagGroup`, and `Tag` lists that content is organized by. Editors and admins
  only (`:live_editor_required`); deletes are admin-only, mirroring the resource
  policies.

  Tags are listed **under their group**, which is also how the content editor's
  picker renders them — see `KilnCMS.CMS.TagGroup`.

  The three kinds are a **lookup table**, not three parallel code paths (#531).
  Adding one used to mean touching ~10 sites — a create/validate `handle_event`
  pair, `create_form/3`, `edit_form/4`, `destroy/4`, `extra_fields/1`,
  `usage_line/1`, `scope_line/1`, `delete_confirm/1`, `none_yet/1`,
  `kind_label/1` and the `<.taxonomy_column>` call — and the module keyed the
  same three kinds three different ways along the way: atoms in one place,
  strings in another, structs in a third. `@kinds` below is now the one
  description of a kind, and everything downstream takes a descriptor from it.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Tag
  alias KilnCMS.CMS.TagGroup

  # One entry per taxonomy kind. `key` is the currency everywhere else: the
  # form's `as:` (so params arrive under it), the `phx-value-type` on the row
  # buttons, and the lookup into `labels/1`.
  #
  # Reads and writes go through the domain's code interfaces by NAME, applied
  # generically (the idiom `ContentTypes.call/3` already uses) — a capture can't
  # live in a module attribute, and calling `Ash.read!`/`Ash.destroy` directly
  # would drop the domain indirection AGENTS.md requires.
  #
  # `loads` is the single statement of which aggregates a kind carries:
  # `load_taxonomy/1` loads exactly these, and `usage_line/2` and
  # `delete_confirm/2` render exactly these. A kind that named an aggregate in
  # one place and not the other used to render `%Ash.NotLoaded{}` into
  # `ngettext/4` — a 500 on the whole page, at render time, with nothing to
  # suggest the table entry was incomplete.
  #
  # `sort: nil` means "whatever the primary read orders by" — `TagGroup`'s is
  # already position-then-name, which an explicit name sort would override.
  @kinds [
    %{
      key: "category",
      resource: Category,
      list: :list_categories!,
      get: :get_category,
      destroy: :destroy_category,
      form: :category_form,
      records: :categories,
      loads: [:page_count, :post_count],
      sort: [name: :asc],
      description?: true,
      extra_fields?: false,
      grouped_by: nil
    },
    %{
      key: "tag_group",
      resource: TagGroup,
      list: :list_tag_groups!,
      get: :get_tag_group,
      destroy: :destroy_tag_group,
      form: :group_form,
      records: :groups,
      loads: [:tag_count],
      sort: nil,
      description?: true,
      extra_fields?: true,
      grouped_by: nil
    },
    %{
      key: "tag",
      resource: Tag,
      list: :list_tags!,
      get: :get_tag,
      destroy: :destroy_tag,
      form: :tag_form,
      records: :tags,
      loads: [:page_count, :post_count],
      sort: [name: :asc],
      description?: false,
      extra_fields?: true,
      # The assign holding this kind's `{key, label, records}` sections. `nil`
      # renders one flat list.
      grouped_by: :grouped_tags
    }
  ]

  @kind_keys ~w(key resource list get destroy form records loads sort description? extra_fields? grouped_by)a

  # A table row with a missing field is a render-time KeyError on a page an
  # editor opens, so check the shape at compile time instead.
  for kind <- @kinds do
    missing = @kind_keys -- Map.keys(kind)

    if missing != [] do
      raise "taxonomy kind #{inspect(kind[:key])} is missing #{inspect(missing)}"
    end
  end

  # Every taxonomy resource should appear in the admin that manages taxonomy.
  # `KilnCMS.CMS.Taxonomy.searchable/0` discovers them from the domain (#530),
  # so this catches a fourth resource that got a search surface and a REST/
  # GraphQL surface from the macro but was never added here.
  taxonomy_resources = Enum.map(KilnCMS.CMS.Taxonomy.searchable(), &elem(&1, 1))
  listed = Enum.map(@kinds, & &1.resource)

  case Enum.sort(taxonomy_resources) -- Enum.sort(listed) do
    [] ->
      :ok

    unlisted ->
      raise "taxonomy resources missing from TaxonomyLive's @kinds: #{inspect(unlisted)}"
  end

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    socket =
      Enum.reduce(@kinds, socket, fn kind, acc ->
        assign(acc, kind.form, create_form(kind, actor, org))
      end)

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:admin?, KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin)
     |> assign(:page_title, gettext("Taxonomy"))
     |> assign(:edit, nil)
     |> assign(:content_type_options, ContentTypes.options(org))
     |> load_taxonomy()}
  end

  # --- create ----------------------------------------------------------------

  @impl true
  # A payload naming no known kind is ignored rather than matched against —
  # `{kind, attrs} = :error` would take the LiveView down and discard every
  # half-typed create form, which is the failure the `edit` handler below
  # exists to avoid. Not reachable from the rendered forms; reachable from a
  # crafted push, and from the next `phx-change` control added to this page.
  def handle_event("validate", params, socket) do
    case kind_params(params) do
      {kind, attrs} ->
        form = AshPhoenix.Form.validate(socket.assigns[kind.form], normalize_types(attrs))
        {:noreply, assign(socket, kind.form, form)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("create", params, socket) do
    case kind_params(params) do
      {kind, attrs} -> create(socket, kind, attrs)
      :error -> {:noreply, socket}
    end
  end

  # --- inline edit -----------------------------------------------------------

  # Non-bang, with an unknown-kind clause: the row this targets may be gone by
  # the time it is clicked (another admin deleted it, or the tab has been open a
  # while), and raising here takes the LiveView down — discarding whatever is
  # half-typed into all three create forms along with it.
  def handle_event("edit", %{"type" => type, "id" => id}, socket)
      when is_binary(type) and is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    with {:ok, kind} <- fetch_kind(type),
         {:ok, record} <- fetch_record(kind, id, actor, org) do
      form =
        record
        |> AshPhoenix.Form.for_update(:update, actor: actor, tenant: org, as: "taxonomy")
        |> to_form()

      {:noreply, assign(socket, :edit, %{type: type, id: id, form: form})}
    else
      _ ->
        {:noreply,
         socket
         |> load_taxonomy()
         |> put_flash(:error, gettext("That item is no longer available."))}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"taxonomy" => params}, socket) when is_map(params) do
    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize_types(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"taxonomy" => params}, socket) when is_map(params) do
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

  def handle_event("delete", %{"type" => type, "id" => id}, socket)
      when is_binary(type) and is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    result =
      with {:ok, kind} <- fetch_kind(type),
           {:ok, record} <- fetch_record(kind, id, actor, org),
           do: apply(CMS, kind.destroy, [record, [actor: actor, tenant: org]])

    {:noreply, after_delete(socket, result, type, id)}
  end

  defp fetch_record(kind, id, actor, org),
    do: apply(CMS, kind.get, [id, [actor: actor, tenant: org]])

  # An in-progress inline edit survives a delete of anything else — clearing it
  # unconditionally threw away a half-typed rename of an unrelated record, and
  # did so even when the delete itself failed. A row in edit mode renders its
  # form instead of its buttons, so the matching case can only arrive from a
  # stale or hand-made payload; it clears then, rather than leaving a form bound
  # to a record that no longer exists.
  defp after_delete(socket, :ok, type, id) do
    socket
    |> load_taxonomy()
    |> put_flash(:info, gettext("Deleted."))
    |> then(fn s -> if editing?(s.assigns.edit, type, id), do: assign(s, :edit, nil), else: s end)
  end

  # Reload on failure too: the commonest failure IS a row that no longer
  # exists, and leaving it on screen means the only affordance is to click
  # Delete again and get the same message.
  defp after_delete(socket, error, _type, _id) do
    socket |> load_taxonomy() |> put_flash(:error, delete_error(error))
  end

  # A row someone else already deleted, a row this actor may not delete, and
  # anything else are three different problems with three different fixes —
  # reporting them all as "you may not have permission" hid the first two.
  #
  # Deliberately NOT `Ash.Error.error_descriptions/1`: it assembles
  # developer-facing text ("Input Invalid\n\n* record with id: \"3f2e…\" not
  # found"), it echoes the primary key back into the UI, and it is always
  # English — interpolating it into a translated frame leaves a hole the
  # catalogs can't see.
  defp delete_error({:error, %Ash.Error.Forbidden{}}),
    do: gettext("You don't have permission to delete that.")

  defp delete_error({:error, %Ash.Error.Invalid{errors: errors}}) do
    if Enum.any?(errors, &is_struct(&1, Ash.Error.Query.NotFound)) do
      # Same wording as the `edit` handler's, because it is the same event:
      # the row on screen is gone.
      gettext("That item is no longer available.")
    else
      gettext("Couldn't delete that.")
    end
  end

  defp delete_error(_other), do: gettext("Couldn't delete that.")

  defp create(socket, kind, attrs) do
    attrs = attrs |> with_slug() |> normalize_types()

    case AshPhoenix.Form.submit(socket.assigns[kind.form], params: attrs) do
      {:ok, _record} ->
        actor = socket.assigns.actor
        org = socket.assigns.current_org

        {:noreply,
         socket
         |> assign(kind.form, create_form(kind, actor, org))
         |> load_taxonomy()
         |> put_flash(:info, labels(kind.key).added)}

      {:error, form} ->
        {:noreply, assign(socket, kind.form, form)}
    end
  end

  # --- data ------------------------------------------------------------------

  defp load_taxonomy(socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      Enum.reduce(@kinds, socket, fn kind, acc ->
        assign(acc, kind.records, read_kind!(kind, actor, org))
      end)

    socket
    |> assign(:grouped_tags, group_tags(socket.assigns.tags, socket.assigns.groups))
    # Assigned here, not in `render/1`: an assign built during render is marked
    # changed on every render, which would re-send every row on every keystroke.
    # This one only moves when the groups do.
    |> assign(:picklists, %{
      groups: socket.assigns.groups,
      content_types: socket.assigns.content_type_options
    })
  end

  # A descriptor by key, for the template. Raises on an unknown key, which is a
  # typo in `render/1` rather than anything a request can cause.
  defp kind(key) do
    Enum.find(@kinds, &(&1.key == key)) || raise ArgumentError, "unknown taxonomy kind: #{key}"
  end

  defp read_kind!(kind, actor, org) do
    query = if kind.sort, do: [sort: kind.sort], else: []

    apply(CMS, kind.list, [[actor: actor, tenant: org, load: kind.loads, query: query]])
  end

  # Tags bucketed by group, in picker order, with "Ungrouped" last. Every group
  # is listed even when empty so editors can see a bucket they've yet to fill;
  # "Ungrouped" only appears when it has something in it.
  #
  # A tag whose `tag_group_id` names no LOADED group — a dangling or cross-tenant
  # FK (`tags.tag_group_id` has no org component), or a group created after the
  # page loaded — falls into "Ungrouped" rather than out of every section (#525).
  # Dropping it hid its Edit/Delete controls, so it couldn't be fixed from the
  # UI, and the "Tags (N)" heading (`length(@records)`) then over-counted the
  # rows actually drawn. Mirrors the editor picker's `bucket_for/3` fallback so
  # the two surfaces agree about the same data.
  #
  # Public only so the bucketing can be unit-tested with hand-built structs: the
  # unknown-group path is unreachable through the DB in the fail-open test suite
  # (both reads are `global?`, so every referenced group loads) and the `nilify`
  # FK forbids a truly dangling `tag_group_id`, so it can't be seeded either.
  @doc false
  def group_tags(tags, groups) do
    known = MapSet.new(groups, & &1.id)

    {grouped, loose} =
      Enum.split_with(tags, &(&1.tag_group_id && MapSet.member?(known, &1.tag_group_id)))

    by_group = Enum.group_by(grouped, & &1.tag_group_id)
    named = Enum.map(groups, &{&1.id, &1.name, Map.get(by_group, &1.id, [])})

    case loose do
      [] -> named
      _ -> named ++ [{nil, gettext("Ungrouped"), loose}]
    end
  end

  # Which kind a create/validate payload came from. The forms serialize under
  # their own `as:` — distinct so input ids stay unique on a page carrying all
  # three — and that key is also what identifies the sender. Not `phx-value-*`:
  # LiveView does not reliably deliver those alongside a `phx-change` payload
  # (#764), and a hidden field would be a second source of truth for something
  # the params already say.
  defp kind_params(params) do
    Enum.find_value(@kinds, :error, fn kind ->
      case Map.fetch(params, kind.key) do
        {:ok, attrs} when is_map(attrs) -> {kind, attrs}
        _ -> nil
      end
    end)
  end

  defp fetch_kind(key) do
    case Enum.find(@kinds, &(&1.key == key)) do
      nil -> :error
      kind -> {:ok, kind}
    end
  end

  # `tenant:` stamps the new row's org so taxonomy is created into the current
  # site (epic #336); `as:` keeps input ids unique across the three create forms
  # (and the inline edit form) on the same page.
  defp create_form(kind, actor, org) do
    kind.resource
    |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: kind.key)
    |> to_form()
  end

  # Fill a blank slug from the name so editors only have to type a label. An
  # explicit slug always wins.
  #
  # `slugify/1` filters to ASCII, so a name written entirely in a non-Latin
  # script ("北京", "Привет") slugifies to `""` — and since #1044 that is a
  # rejected write rather than a silently empty slug, which would leave a
  # Chinese- or Russian-language site unable to add a category at all without
  # an editor inventing a Latin slug by hand. Content already solves this:
  # `Slugs.ensure_unique/2` falls back to a random suffix. Same answer here,
  # and an editor who wants a meaningful slug can still type one.
  defp with_slug(params) do
    name = Map.get(params, "name", "")

    case String.trim(Map.get(params, "slug", "")) do
      "" -> Map.put(params, "slug", derived_slug(name))
      _slug -> params
    end
  end

  defp derived_slug(name) do
    case KilnCMS.Slug.slugify(name) do
      "" -> KilnCMS.Slug.random_suffix()
      slug -> slug
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

        <%!-- Three explicit calls, not a `:for` over `@kinds`. A comprehension
              would have to pair each kind with its form and record list, and
              building those pairs in `render/1` puts them behind an assign
              LiveView marks changed every time — so one keystroke in any create
              form re-serializes every category, group and tag row over the
              socket (measured: an incremental diff going from ~8% of a full
              render to ~52%, and growing with the row count). Referencing the
              tracked assigns directly keeps a validate patch scoped to the one
              column that changed. Adding a kind costs a line here; sending the
              whole page on every keystroke costs more. --%>
        <div class="grid gap-8 lg:grid-cols-2">
          <.taxonomy_column
            kind={kind("category")}
            form={@category_form}
            records={@categories}
            edit={@edit}
            admin?={@admin?}
            picklists={@picklists}
          />
          <.taxonomy_column
            kind={kind("tag_group")}
            form={@group_form}
            records={@groups}
            edit={@edit}
            admin?={@admin?}
            picklists={@picklists}
          />
        </div>

        <.taxonomy_column
          kind={kind("tag")}
          form={@tag_form}
          records={@tags}
          grouped={@grouped_tags}
          edit={@edit}
          admin?={@admin?}
          picklists={@picklists}
        />
      </div>
    </Layouts.console>
    """
  end

  attr :kind, :map, required: true
  attr :form, :any, required: true
  attr :records, :list, required: true
  attr :edit, :any, required: true
  attr :admin?, :boolean, required: true
  # The page's pick-list data — `%{groups:, content_types:}`. One assign rather
  # than one attr per list: which of them a column reads is `extra_fields/1`'s
  # business, not the column's.
  attr :picklists, :map, required: true
  # `nil` renders one flat list; otherwise `{key, label, records}` sections.
  attr :grouped, :any, default: nil

  defp taxonomy_column(assigns) do
    assigns = assign(assigns, :labels, labels(assigns.kind.key))

    ~H"""
    <section class="space-y-4">
      <div>
        <h2 class="text-lg font-medium">{@labels.heading} ({length(@records)})</h2>
        <p class="text-sm text-base-content/60">{@labels.blurb}</p>
      </div>

      <.form
        for={@form}
        id={"new-#{@kind.key}-form"}
        phx-change="validate"
        phx-submit="create"
        class="card card-pad space-y-3"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:name]}
            label={gettext("Name")}
            placeholder={gettext("New %{kind} name", kind: @labels.noun)}
          />
          <.input
            field={@form[:slug]}
            label={gettext("Slug")}
            placeholder={gettext("Auto from name")}
          />
        </div>
        <.input
          :if={@kind.description?}
          field={@form[:description]}
          type="textarea"
          label={gettext("Description")}
        />
        <.extra_fields kind={@kind} form={@form} picklists={@picklists} />
        <.button type="submit" variant="primary">
          {gettext("Add %{kind}", kind: @labels.noun)}
        </.button>
      </.form>

      <p :if={@records == []} class="text-sm text-base-content/60">
        {@labels.none_yet}
      </p>

      <ul :if={@records != [] and is_nil(@grouped)} class="card divide-y divide-base-content/10">
        <.taxonomy_row
          :for={record <- @records}
          record={record}
          kind={@kind}
          edit={@edit}
          admin?={@admin?}
          picklists={@picklists}
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
              picklists={@picklists}
            />
          </ul>
        </section>
      </div>
    </section>
    """
  end

  attr :record, :any, required: true
  attr :kind, :map, required: true
  attr :edit, :any, required: true
  attr :admin?, :boolean, required: true
  attr :picklists, :map, required: true

  defp taxonomy_row(assigns) do
    # Only `scope_line/3` is precomputed: it is the one that needs `picklists`,
    # and hoisting it keeps the template readable. `usage_line/2` and
    # `delete_confirm/2` stay inline so they run only for the branch that shows
    # them — the confirm text in particular is admin-only, and computing it for
    # every row a viewer sees is work nobody reads.
    assigns =
      assign(
        assigns,
        :scope,
        scope_line(assigns.kind, assigns.record, assigns.picklists.content_types)
      )

    ~H"""
    <li class="p-3">
      <div
        :if={!editing?(@edit, @kind.key, @record.id)}
        class="flex items-start justify-between gap-3"
      >
        <div class="min-w-0">
          <p class="truncate font-medium">{@record.name}</p>
          <p class="truncate text-xs text-base-content/70">
            <code>{@record.slug}</code> · {usage_line(@kind, @record)}
          </p>
          <p :if={@scope} class="truncate text-xs text-base-content/50">{@scope}</p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            phx-click="edit"
            phx-value-type={@kind.key}
            phx-value-id={@record.id}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Edit")}
          </button>
          <button
            :if={@admin?}
            type="button"
            phx-click="delete"
            phx-value-type={@kind.key}
            phx-value-id={@record.id}
            data-confirm={delete_confirm(@kind, @record)}
            aria-label={gettext("Delete %{name}", name: @record.name)}
            class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>

      <.form
        :if={editing?(@edit, @kind.key, @record.id)}
        for={@edit.form}
        id={"edit-#{@kind.key}-#{@record.id}"}
        phx-change="validate_edit"
        phx-submit="save_edit"
        class="space-y-3"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <.input field={@edit.form[:name]} label={gettext("Name")} />
          <.input field={@edit.form[:slug]} label={gettext("Slug")} />
        </div>
        <.input
          :if={@kind.description?}
          field={@edit.form[:description]}
          type="textarea"
          label={gettext("Description")}
        />
        <.extra_fields kind={@kind} form={@edit.form} picklists={@picklists} />
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
  attr :kind, :map, required: true
  attr :form, :any, required: true
  attr :picklists, :map, required: true

  defp extra_fields(%{kind: %{key: "tag_group"}} = assigns) do
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
          :for={{label, value} <- @picklists.content_types}
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

  defp extra_fields(%{kind: %{key: "tag"}} = assigns) do
    ~H"""
    <.input
      field={@form[:tag_group_id]}
      type="select"
      label={gettext("Group")}
      prompt={gettext("— Ungrouped —")}
      options={Enum.map(@picklists.groups, &{&1.name, &1.id})}
    />
    """
  end

  # A kind with nothing beyond the shared trio.
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

  # Every literal a kind needs, in one clause per kind. These can't live in
  # `@kinds` itself: `gettext/1` has to see a literal at the call site, and a
  # module attribute would freeze the translation at compile time instead of
  # resolving it per request locale.
  defp labels("category"),
    do: %{
      heading: gettext("Categories"),
      blurb: gettext("A piece of content belongs to one category."),
      none_yet: gettext("No categories yet."),
      # The translated noun for interpolations like "Add %{kind}" — the raw key
      # would surface untranslated English ("Ajouter category").
      noun: gettext("category"),
      # A whole sentence, not "%{noun} added." — interpolating a noun into a
      # frame gets the case and gender wrong in most languages that have them.
      added: gettext("Category added.")
    }

  defp labels("tag_group"),
    do: %{
      heading: gettext("Tag groups"),
      blurb:
        gettext("Buckets that tags are filed under, so the editor's tag picker stays scannable."),
      none_yet: gettext("No tag groups yet."),
      noun: gettext("tag group"),
      added: gettext("Tag group added.")
    }

  defp labels("tag"),
    do: %{
      heading: gettext("Tags"),
      blurb: gettext("Content can carry any number of tags."),
      none_yet: gettext("No tags yet."),
      noun: gettext("tag"),
      added: gettext("Tag added.")
    }

  # The "· N pages, N posts" (or "· N tags") line under a record's slug —
  # assembled from the kind's OWN `loads`, so it can't fall out of step with
  # what was loaded. One `count_phrase/2` clause per aggregate, because
  # `ngettext/4` needs literals.
  defp usage_line(kind, record),
    do: Enum.map_join(kind.loads, ", ", &count_phrase(&1, Map.fetch!(record, &1)))

  defp count_phrase(:page_count, n), do: ngettext("%{count} page", "%{count} pages", n, count: n)
  defp count_phrase(:post_count, n), do: ngettext("%{count} post", "%{count} posts", n, count: n)
  defp count_phrase(:tag_count, n), do: ngettext("%{count} tag", "%{count} tags", n, count: n)

  # How many things a record is holding onto, for the delete confirmation —
  # same source as the usage line.
  defp usage_total(kind, record),
    do: kind.loads |> Enum.map(&Map.fetch!(record, &1)) |> Enum.sum()

  # Only tag groups carry a content-type scope; nil hides the line entirely.
  defp scope_line(%{key: "tag_group"}, %{content_types: []}, _options),
    do: gettext("All content types")

  # Render from resolved labels, not the raw stored strings: an entry that names
  # no live type (a renamed/archived `TypeDefinition`, or a bad write predating
  # the `KnownContentTypes` validation) shows as "recipe (unknown)" rather than
  # "Only: recipe", which is indistinguishable from a type that exists (#526).
  defp scope_line(%{key: "tag_group"}, %{content_types: types}, options) do
    labels = Map.new(options, fn {label, type} -> {type, label} end)

    rendered =
      Enum.map_join(types, ", ", fn type ->
        case Map.get(labels, type) do
          nil -> gettext("%{type} (unknown)", type: type)
          label -> label
        end
      end)

    gettext("Only: %{types}", types: rendered)
  end

  defp scope_line(_kind, _record, _options), do: nil

  # Deleting a group keeps its tags (the FK nilifies); deleting a category or
  # tag removes the links — different consequences, so different sentences.
  defp delete_confirm(%{key: "tag_group"} = kind, group) do
    case usage_total(kind, group) do
      0 ->
        gettext("Delete “%{name}”?", name: group.name)

      n ->
        gettext(
          "“%{name}” holds %{count} tag(s). Delete the group anyway? The tags are kept and become ungrouped.",
          name: group.name,
          count: n
        )
    end
  end

  defp delete_confirm(kind, record) do
    case usage_total(kind, record) do
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
end
