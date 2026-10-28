defmodule KilnCMSWeb.FieldDefinitionLive do
  @moduledoc """
  Custom fields (`/editor/fields`) — the admin-UI-first half of the schema. An
  admin defines typed custom fields per content type (the Directus "add a field
  in the UI" workflow, within decision D4); the content editor then renders an
  input per definition and `Changes.ApplyCustomFields` coerces/validates the
  values into each record's `custom_fields` map. Admin-only, mirroring the
  `FieldDefinition` policy.

  Fields attach to either a **built-in** (compiled) content type or an
  admin-defined **dynamic** one (`/editor/types` — decision D17). Each type
  checkbox encodes a scope: a compiled type's atom name, or `"def:<uuid>"` for
  a dynamic type, unpacked into `content_type` XOR `type_definition_id` by
  `normalize/2`.

  A definition still has exactly one owner, so ticking several types creates one
  definition per type under the same machine name. Each is then its own row —
  edited, renamed or deleted without touching the others — while delivery sees
  the same `custom_fields` key on every type that carries it.

  The machine name follows the label as it is typed until the admin edits the
  name themselves, and a name already defined on a ticked type is refused before
  anything is written — for every ticked type, not only the first.

  A reference field carries its **link fields** (R3) under it, as "Details on
  each connection": the quantity of each ingredient a recipe connects, the
  role of each author. They are added, edited, ordered and deleted in place,
  one small form at a time, and offer only the plain field types
  (`FieldDefinition.link_field_types/0`).

  A `:group` field carries its **sub-fields** the same way, as "Fields in
  each row": the amount and the unit of each dosage. The same small forms add,
  edit, order and delete them, with the same plain types; only the parent
  column differs (`group_of_id` rather than `link_of_id`), because a
  sub-field's value lives inside the group's own value.

  Both forms first ask what a field holds: a value, or a relationship (R9,
  #2025, after Toolset's relationship wizard). A relationship is a
  `:reference` field set up in four steps — which records connect, how many
  on each side, what each side calls it, and the delete rule — and read back
  as one sentence from both sides. The steps only reword the stored options
  (`target_type(s)`, `multiple`, `min_items`/`max_items`, `max_sources`,
  `inverse_label`/`inverse_name`, `on_target_delete`).
  """
  use KilnCMSWeb, :live_view

  # The field types a typed-in default applies to (#1820): the ones
  # `ApplyCustomFields` coerces a default to. A media item or a reference is
  # picked, not typed; a computed field derives its value; and the composite
  # and plugin types take a shape a single box can't give.
  @default_types ~w(string text url integer float boolean date datetime select)

  import KilnCMSWeb.ComputedBuilderComponents, only: [compute_builder: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMSWeb.ComputedBuilder

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("Custom fields"))
       |> assign(:content_types, ContentTypes.all())
       |> assign(:dynamic_types, ContentTypes.dynamic_all(org))
       |> assign(:field_types, FieldDefinition.field_types())
       |> assign(:target_types, ContentTypes.options(org))
       |> assign(:edit, nil)
       |> assign(:link_form, nil)
       |> assign(:default_scopes, [])
       |> assign(:samples, %{})
       # The builder's static lists, built once: each is a page of gettext
       # calls, and rebuilding them per keystroke is wasted work.
       |> assign(:recipes, Computed.Recipes.all())
       |> assign(:function_categories, KilnCMSWeb.ComputedBuilderComponents.categories())
       |> reset_create_form()
       |> load_definitions()
       |> assign_create_builder()}
    else
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # redirects non-admins before mount; mirror its flash here for consistency.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # `?type=<scope>` arrives from the content-types screen right after a type is
  # created (#1817), and from its "Manage fields" link: that type starts ticked,
  # and stays ticked after each field is added. Only a scope this page offers a
  # checkbox for is taken — anything else is ignored rather than trusted.
  @impl true
  def handle_params(params, _uri, %{assigns: %{content_types: _}} = socket) do
    offered = scope_values(socket.assigns)
    default_scopes = params |> Map.get("type") |> List.wrap() |> Enum.filter(&(&1 in offered))

    {:noreply,
     socket
     |> assign(:default_scopes, default_scopes)
     |> assign(:scopes, default_scopes)
     |> assign_create_builder()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"field_definition" => params} = event, socket)
      when is_map(params) do
    params = apply_kind(params)
    scopes = selected_scopes(params)
    name_edited? = name_edited?(event["_target"], params, socket.assigns.name_edited?)
    params = if name_edited?, do: params, else: suggest_name(params)
    params = drop_default_on_type_change(params, socket.assigns.form)
    {params, builder} = ComputedBuilder.apply_params(params, socket.assigns.builder)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.validate(normalize(params, List.first(scopes)))
      |> refuse_duplicates(params, scopes, socket.assigns)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:scopes, scopes)
     |> assign(:name_edited?, name_edited?)
     |> assign(:scope_error, nil)
     |> assign(:builder, builder)
     |> assign_create_builder()}
  end

  def handle_event("create", %{"field_definition" => params}, socket) when is_map(params) do
    params = apply_kind(params)
    scopes = selected_scopes(params)
    # A submit without a preceding change event (or with the name cleared)
    # still gets the name its label suggests.
    params = if blank?(params["name"]), do: suggest_name(params), else: params
    {params, builder} = ComputedBuilder.apply_params(params, socket.assigns.builder)
    assigns = socket.assigns
    socket = socket |> assign(:scopes, scopes) |> assign(:builder, builder)

    forms =
      Enum.map(scopes, fn scope ->
        # A new field goes to the end of its type's list (#1818); the list's
        # drag handles and arrows move it from there.
        params =
          params
          |> normalize(scope)
          |> Map.put("position", next_position(assigns.definitions, scope))

        assigns.actor
        |> create_form(assigns.current_org)
        |> AshPhoenix.Form.validate(params)
        |> refuse_duplicates(params, scopes, assigns)
      end)

    cond do
      scopes == [] ->
        {:noreply,
         socket
         |> assign(:form, AshPhoenix.Form.validate(assigns.form, normalize(params, nil)))
         |> assign(:scope_error, gettext("Pick at least one content type."))}

      invalid = Enum.find(forms, &(not &1.source.valid?)) ->
        # Submitting an invalid form writes nothing; it is what marks every
        # error on it for display.
        {:error, form} = AshPhoenix.Form.submit(invalid, params: nil)
        {:noreply, socket |> assign(:form, form) |> assign_create_builder()}

      true ->
        {:noreply, create_all(socket, forms)}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) when is_binary(id) do
    form = edit_form(id, socket.assigns.actor, socket.assigns.current_org)

    {:noreply,
     socket
     |> assign(:edit, %{
       id: id,
       form: form,
       builder: ComputedBuilder.new(form[:compute].value),
       ctx: nil
     })
     |> assign_edit_builder()}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"field_definition" => params}, socket)
      when is_map(params) do
    params = params |> apply_kind() |> drop_default_on_type_change(socket.assigns.edit.form)
    {params, builder} = ComputedBuilder.apply_params(params, socket.assigns.edit.builder)

    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize(params)),
        builder: builder
    }

    {:noreply, socket |> assign(:edit, edit) |> assign_edit_builder()}
  end

  def handle_event("save_edit", %{"field_definition" => params}, socket) when is_map(params) do
    {params, builder} =
      params |> apply_kind() |> ComputedBuilder.apply_params(socket.assigns.edit.builder)

    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: normalize(params)) do
      {:ok, _definition} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_definitions() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:edit, %{socket.assigns.edit | form: form, builder: builder})
         |> assign_edit_builder()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, definition} <- CMS.get_field_definition(id, actor: actor, tenant: org),
           :ok <- CMS.destroy_field_definition(definition, actor: actor, tenant: org) do
        socket |> load_definitions() |> put_flash(:info, gettext("Field deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that field."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- link fields (R3) -----------------------------------------------------

  # "Add a detail" under a reference field, or "Add a field" under a group: a
  # small create form scoped to it. Which of the two the parent is decides the
  # column the new row is owned through (`link_params/3`).
  def handle_event("link_new", %{"parent" => parent_id}, socket) when is_binary(parent_id) do
    case Enum.find(socket.assigns.definitions, &(&1.id == parent_id)) do
      %{field_type: type} when type in [:reference, :group] ->
        form = link_create_form(socket.assigns.actor, socket.assigns.current_org, parent_id)

        {:noreply,
         assign(socket, :link_form, %{
           parent: parent_id,
           kind: child_kind(type),
           id: nil,
           form: form,
           name_edited?: false
         })}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("link_edit", %{"id" => id}, socket) when is_binary(id) do
    case find_link(socket, id) do
      nil ->
        {:noreply, socket}

      link ->
        form = link_edit_form(link, socket.assigns.actor, socket.assigns.current_org)

        {:noreply,
         assign(socket, :link_form, %{
           parent: FieldDefinition.parent_id(link),
           kind: if(link.group_of_id, do: :group, else: :link),
           id: id,
           form: form,
           name_edited?: true
         })}
    end
  end

  def handle_event("link_cancel", _params, socket),
    do: {:noreply, assign(socket, :link_form, nil)}

  def handle_event(
        "link_validate",
        %{"link_field" => params} = event,
        %{assigns: %{link_form: %{} = lf}} = socket
      )
      when is_map(params) do
    name_edited? =
      lf.id != nil or name_edited?(event["_target"], params, lf.name_edited?, "link_field")

    params = if name_edited?, do: params, else: suggest_name(params)
    params = drop_default_on_type_change(params, lf.form)
    form = AshPhoenix.Form.validate(lf.form, link_params(params, lf))

    {:noreply, assign(socket, :link_form, %{lf | form: form, name_edited?: name_edited?})}
  end

  def handle_event(
        "link_save",
        %{"link_field" => params},
        %{assigns: %{link_form: %{} = lf}} = socket
      )
      when is_map(params) do
    params = if lf.id == nil and blank?(params["name"]), do: suggest_name(params), else: params

    case AshPhoenix.Form.submit(lf.form, params: link_params(params, lf, socket.assigns)) do
      {:ok, _link} ->
        {:noreply,
         socket
         |> assign(:link_form, nil)
         |> load_definitions()
         |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :link_form, %{lf | form: form})}
    end
  end

  # A change or submit from a form no longer open (cancelled in another tab).
  def handle_event(event, _params, socket) when event in ["link_validate", "link_save"],
    do: {:noreply, socket}

  def handle_event("link_move", %{"id" => id, "dir" => dir}, socket)
      when is_binary(id) and dir in ["up", "down"] do
    with %{} = link <- find_link(socket, id),
         parent_id = FieldDefinition.parent_id(link),
         ids = socket.assigns.link_fields |> Map.get(parent_id, []) |> Enum.map(& &1.id),
         index when is_integer(index) <- Enum.find_index(ids, &(&1 == id)),
         target = if(dir == "up", do: index - 1, else: index + 1),
         true <- target >= 0 and target < length(ids) do
      moved = ids |> List.delete_at(index) |> List.insert_at(target, id)
      {:noreply, reorder_links(socket, parent_id, moved)}
    else
      _ -> {:noreply, socket}
    end
  end

  # --- order (#1818) ---------------------------------------------------------

  # Pushed by the `Sortable` hook with one type's list in its new order.
  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    {:noreply, reorder(socket, order)}
  end

  # The arrow buttons: the same reorder, one step, from a keyboard or a screen
  # reader — dragging is the fast path, not the only one.
  def handle_event("move_field", %{"id" => id, "dir" => dir}, socket)
      when is_binary(id) and dir in ["up", "down"] do
    order =
      Enum.find_value(socket.assigns.grouped, [], fn {_scope, definitions} ->
        ids = Enum.map(definitions, & &1.id)
        if id in ids, do: ids
      end)

    index = Enum.find_index(order, &(&1 == id))
    target = if dir == "up", do: (index || 0) - 1, else: (index || 0) + 1

    if index && target >= 0 && target < length(order) do
      moved = order |> List.delete_at(index) |> List.insert_at(target, id)
      {:noreply, reorder(socket, moved)}
    else
      {:noreply, socket}
    end
  end

  # --- create helpers --------------------------------------------------------

  # Every form already validated, so a failure here is a write that raced this
  # one (another admin defining the same name a moment earlier). Earlier types
  # in the list keep their field; the flash says which, rather than implying
  # nothing happened.
  defp create_all(socket, forms) do
    result =
      Enum.reduce_while(forms, [], fn form, created ->
        case AshPhoenix.Form.submit(form, params: nil) do
          {:ok, definition} -> {:cont, [definition | created]}
          {:error, form} -> {:halt, {created, form}}
        end
      end)

    case result do
      {created, form} ->
        socket
        |> assign(:form, form)
        |> load_definitions()
        |> put_flash(:error, partial_create_message(created, socket.assigns.dynamic_types))

      created ->
        socket
        |> reset_create_form()
        |> load_definitions()
        |> put_flash(
          :info,
          ngettext("Field added.", "Field added to %{count} content types.", length(created))
        )
    end
  end

  defp partial_create_message([], _dynamic_types), do: gettext("Couldn't add that field.")

  defp partial_create_message(created, dynamic_types) do
    types =
      created
      |> Enum.reverse()
      |> Enum.map_join(", ", &group_heading(scope_key(&1), dynamic_types))

    gettext("Added to %{types} only — the next content type refused it.", types: types)
  end

  defp reset_create_form(socket) do
    socket
    |> assign(:form, create_form(socket.assigns.actor, socket.assigns.current_org))
    |> assign(:scopes, socket.assigns.default_scopes)
    |> assign(:scope_error, nil)
    |> assign(:name_edited?, false)
    |> assign(:builder, ComputedBuilder.new())
  end

  # The machine name tracks the label until the admin types into the name
  # input; clearing that input hands it back to the label.
  defp name_edited?(target, params, edited?, as \\ "field_definition")

  defp name_edited?([as, "name"], params, _edited?, as),
    do: not blank?(params["name"])

  defp name_edited?(_target, _params, edited?, _as), do: edited?

  defp suggest_name(params),
    do: Map.put(params, "name", FieldDefinition.name_from_label(params["label"]))

  defp blank?(value), do: value in [nil, ""]

  # Both forms first ask what the field holds (R9): a value typed into each
  # record, or a connection to other records. A connection is a `:reference`
  # field, whose type picker the form then leaves out; going back to a value
  # starts from plain text. A post with no choice (an API-shaped submit)
  # keeps the type it names.
  defp apply_kind(%{"kind" => "relationship"} = params),
    do: Map.put(params, "field_type", "reference")

  defp apply_kind(%{"kind" => "value", "field_type" => "reference"} = params),
    do: Map.put(params, "field_type", "string")

  defp apply_kind(params), do: params

  # Every scope a type checkbox is rendered for.
  defp scope_values(assigns) do
    Enum.map(assigns.content_types, &to_string(&1.type)) ++
      Enum.map(assigns.dynamic_types, &"def:#{&1.definition.id}")
  end

  # A default typed for one field type means nothing for another — "abc" is no
  # number, and a select's default must be one of its options — so picking a
  # different type starts the default over (#1820).
  defp drop_default_on_type_change(%{"field_type" => type} = params, form)
       when is_binary(type) do
    if type == to_string(form[:field_type].value),
      do: params,
      else: Map.put(params, "default", "")
  end

  defp drop_default_on_type_change(params, _form), do: params

  # --- formula builder -------------------------------------------------------

  # The builder's values, samples and preview for the add form. A formula is
  # shared by every type ticked, so the value picker offers the fields of all
  # of them; the preview runs on the first.
  defp assign_create_builder(socket) do
    %{form: form, scopes: scopes, builder: builder} = socket.assigns

    if computed?(form) do
      {socket, ctx} =
        builder_ctx(socket, scopes, form[:compute].value, builder, own_name(form))

      assign(socket, :builder_ctx, ctx)
    else
      assign(socket, :builder_ctx, nil)
    end
  end

  defp assign_edit_builder(%{assigns: %{edit: edit}} = socket) do
    definition = Enum.find(socket.assigns.definitions, &(&1.id == edit.id))

    if definition && computed?(edit.form) do
      {socket, ctx} =
        builder_ctx(
          socket,
          [scope_param(definition)],
          edit.form[:compute].value,
          edit.builder,
          definition.name
        )

      assign(socket, :edit, %{edit | ctx: ctx})
    else
      socket
    end
  end

  # The name being typed on the add form, so the pickers can leave out a
  # computed field that already reads it.
  defp own_name(form) do
    case form[:name].value do
      name when is_binary(name) and name != "" -> name
      _blank -> nil
    end
  end

  defp builder_ctx(socket, scopes, compute, builder, own_name) do
    scope = List.first(scopes)
    {socket, documents} = samples(socket, scope)
    sample = Enum.find(documents, &(&1.id == builder.sample)) || List.first(documents)

    # The site's date, pinned as every other evaluation site pins one, so a
    # `today()` formula previews what a save made right now would store.
    today = Computed.Context.today()

    # Projected onto the type's current editable fields, as the write path
    # (`ApplyCustomFields`) and firing both do: a value left in the jsonb by a
    # field deleted since must not preview a result the save would never give.
    context =
      if sample,
        do:
          Computed.Context.from_document(
            sample,
            Map.take(
              sample.custom_fields || %{},
              editable_names(socket.assigns.definitions, scope)
            ),
            today
          ),
        else: sample_context(today)

    # The type's other computed fields, derived fresh in dependency order as
    # the save would — so a formula over one previews that field's value, not
    # whatever the sample stored last.
    others = other_computed(socket.assigns.definitions, scope, own_name)
    context = %{context | fields: Computed.derive(others, context, context.fields)}

    {socket,
     %{
       values: value_options(socket.assigns.definitions, scopes, own_name),
       samples: Enum.map(documents, &{sample_label(&1), &1.id}),
       sample: sample && sample.id,
       preview: ComputedBuilder.preview(compute, context),
       today: today,
       time_dependent?: Computed.time_dependent?(compute)
     }}
  end

  # The values a formula may reference: the document's own, this type's other
  # editable fields, then its other computed fields — less any that already
  # read this one, directly or through another, since referencing it would
  # close a loop the save refuses. A field sharing a document value's name is
  # reached as `field.<name>`.
  defp value_options(definitions, scopes, own_name) do
    in_scope =
      definitions
      |> Enum.filter(&(scope_param(&1) in scopes and &1.name != own_name))
      |> Enum.uniq_by(& &1.name)

    {computed, editable} = Enum.split_with(in_scope, &(&1.field_type == :computed))

    loops = if own_name, do: Computed.readers(computed, own_name), else: []

    computed = Enum.reject(computed, &(&1.name in loops))

    document = Enum.map(Computed.document_refs(), &{document_ref_label(&1), &1})

    Enum.reject(
      [
        {gettext("This document"), document},
        {gettext("Custom fields"), Enum.map(editable, &{&1.label, field_ref(&1.name)})},
        {gettext("Computed fields"), Enum.map(computed, &{&1.label, field_ref(&1.name)})}
      ],
      &match?({_group, []}, &1)
    )
  end

  defp other_computed(definitions, scope, own_name) do
    Enum.filter(
      definitions,
      &(&1.field_type == :computed and scope_param(&1) == scope and &1.name != own_name)
    )
  end

  defp field_ref(name),
    do: if(name in Computed.document_refs(), do: "field." <> name, else: name)

  defp document_ref_label("title"), do: gettext("Title")
  defp document_ref_label("slug"), do: gettext("Slug")
  defp document_ref_label("locale"), do: gettext("Language")
  defp document_ref_label("excerpt"), do: gettext("Summary")
  defp document_ref_label("body"), do: gettext("Body text")
  defp document_ref_label("seo_title"), do: gettext("SEO title")
  defp document_ref_label("seo_description"), do: gettext("SEO description")
  defp document_ref_label("seo_keywords"), do: gettext("SEO keywords")
  defp document_ref_label(ref), do: ref

  # A computed field's stored value is left out, along with any key no
  # definition declares: the preview derives the computed ones fresh.
  defp editable_names(definitions, scope) do
    for definition <- definitions,
        definition.field_type != :computed,
        scope_param(definition) == scope,
        do: definition.name
  end

  # A type's five most recently edited documents, read once per type per page
  # visit — the preview re-evaluates on every keystroke, but against these.
  defp samples(socket, nil), do: {socket, []}

  defp samples(%{assigns: %{samples: cache}} = socket, scope) do
    case Map.fetch(cache, scope) do
      {:ok, documents} ->
        {socket, documents}

      :error ->
        documents = load_samples(socket.assigns, scope)
        {assign(socket, :samples, Map.put(cache, scope, documents)), documents}
    end
  end

  defp load_samples(assigns, scope) do
    descriptor =
      case scope do
        "def:" <> id -> Enum.find(assigns.dynamic_types, &(&1.definition.id == id))
        type -> Enum.find(assigns.content_types, &(to_string(&1.type) == type))
      end

    if descriptor do
      ContentTypes.list!(descriptor,
        actor: assigns.actor,
        tenant: assigns.current_org,
        query: [sort: [updated_at: :desc], limit: 5]
      )
    else
      []
    end
  end

  defp sample_label(%{title: title}) when is_binary(title) and title != "", do: title
  defp sample_label(_document), do: gettext("Untitled")

  # What the preview runs on for a type with no content yet: enough body text
  # that reading time and word count say something.
  defp sample_context(today) do
    title = gettext("A sample title")

    %{
      document: %{
        "title" => title,
        "slug" => KilnCMS.Slug.slugify(title),
        "locale" => "en",
        "excerpt" => gettext("A short summary of the sample document."),
        "body" => String.duplicate(gettext("Sample body text for the preview. "), 80)
      },
      fields: %{},
      today: today
    }
  end

  # --- link-field helpers (R3) ---------------------------------------------

  defp find_link(socket, id) do
    socket.assigns.link_fields |> Map.values() |> List.flatten() |> Enum.find(&(&1.id == id))
  end

  defp link_create_form(actor, org, parent_id) do
    FieldDefinition
    |> AshPhoenix.Form.for_create(:create,
      actor: actor,
      tenant: org,
      as: "link_field",
      id: "link_field_new_#{parent_id}",
      params: %{"field_type" => "string"}
    )
    |> to_form()
  end

  defp link_edit_form(link, actor, org) do
    link
    |> AshPhoenix.Form.for_update(:update,
      actor: actor,
      tenant: org,
      as: "link_field",
      id: "link_field_#{link.id}"
    )
    |> to_form()
  end

  defp child_kind(:group), do: :group
  defp child_kind(_reference), do: :link

  # The same option/default clean-up as a field's own form. A new link field
  # (or group sub-field) is pinned to the parent it was opened under and goes
  # to the end of its list; an edit never moves it.
  defp link_params(params, link_form, assigns \\ nil)

  defp link_params(params, %{id: nil, parent: parent_id, kind: kind}, assigns) do
    column = if kind == :group, do: "group_of_id", else: "link_of_id"
    params = params |> normalize() |> Map.put(column, parent_id)

    case assigns do
      nil -> params
      assigns -> Map.put(params, "position", length(Map.get(assigns.link_fields, parent_id, [])))
    end
  end

  defp link_params(params, _link_form, _assigns),
    do: params |> normalize() |> Map.drop(["link_of_id", "group_of_id"])

  defp reorder_links(socket, parent_id, order) do
    by_id = socket.assigns.link_fields |> Map.get(parent_id, []) |> Map.new(&{&1.id, &1})
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    failed =
      order
      |> Enum.with_index()
      |> Enum.filter(fn {id, index} ->
        by_id[id].position != index and
          not match?({:ok, _}, CMS.update_field_definition(by_id[id], %{position: index}, opts))
      end)

    socket = load_definitions(socket)

    if failed == [],
      do: socket,
      else: put_flash(socket, :error, gettext("Couldn't save the new order of details."))
  end

  defp link_type_options do
    Enum.map(FieldDefinition.link_field_types(), &{type_label(&1), &1})
  end

  # --- order helpers ---------------------------------------------------------

  # Positions are rewritten as 0, 1, 2… down one type's list, so the editor
  # shows the fields in exactly the order this list does. The order must be a
  # whole list as rendered — a stale page or a hand-made event that names some
  # other set of ids changes nothing.
  defp reorder(socket, order) do
    group =
      Enum.find_value(socket.assigns.grouped, fn {_scope, definitions} ->
        if Enum.sort(Enum.map(definitions, & &1.id)) == Enum.sort(order), do: definitions
      end)

    case group do
      nil ->
        load_definitions(socket)

      definitions ->
        by_id = Map.new(definitions, &{&1.id, &1})
        opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

        # Only the rows whose position moved are written.
        failed =
          order
          |> Enum.with_index()
          |> Enum.filter(fn {id, index} ->
            by_id[id].position != index and
              not match?(
                {:ok, _},
                CMS.update_field_definition(by_id[id], %{position: index}, opts)
              )
          end)

        socket = load_definitions(socket)

        if failed == [],
          do: socket,
          else: put_flash(socket, :error, gettext("Couldn't save the new order of fields."))
    end
  end

  # One past the last position on a type, so a new field is listed (and shown
  # in the editor) last.
  defp next_position(definitions, scope) do
    definitions
    |> Enum.filter(&(scope_param(&1) == scope))
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  # The ticked type checkboxes. The hidden `""` keeps the key present when every
  # box is cleared.
  defp selected_scopes(params) do
    params
    |> Map.get("scopes", [])
    |> List.wrap()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  # A name already defined on any ticked type. The identities refuse it too,
  # but only at insert, one type at a time — and only after the types before it
  # were written.
  defp refuse_duplicates(form, params, scopes, assigns) do
    name = params["name"]

    taken_on =
      assigns.definitions
      |> Enum.filter(&(&1.name == name and scope_param(&1) in scopes))
      |> Enum.map(&group_heading(scope_key(&1), assigns.dynamic_types))

    if blank?(name) or taken_on == [] do
      form
    else
      # Translated here: resource messages reach `translate_error/1` as msgids
      # of the untranslated "errors" domain, so this one falls back to itself.
      message = gettext("is already a field on %{types}", types: Enum.join(taken_on, ", "))

      AshPhoenix.Form.add_error(
        form,
        Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: message)
      )
    end
  end

  # --- data ------------------------------------------------------------------

  defp load_definitions(socket) do
    {links, definitions} =
      CMS.list_field_definitions!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [position: :asc, name: :asc]]
      )
      # Link fields (R3) are listed under their reference field, and a
      # group's sub-fields under their group — not as fields of a type.
      |> Enum.split_with(&(not is_nil(FieldDefinition.parent_id(&1))))

    # A definition whose content type no longer exists (#1770) is listed on
    # its own, with only a delete: nothing renders, validates or delivers it,
    # and it cannot be saved back while it points at nothing.
    {orphaned, owned} = Enum.split_with(definitions, &FieldDefinition.orphaned?/1)

    grouped =
      owned
      |> Enum.group_by(&scope_key/1)
      |> Enum.sort_by(fn {scope, _definitions} ->
        group_heading(scope, socket.assigns.dynamic_types)
      end)

    socket
    |> assign(:definitions, definitions)
    |> assign(:link_fields, Enum.group_by(links, &FieldDefinition.parent_id/1))
    |> assign(:grouped, grouped)
    |> assign(:orphaned, Enum.sort_by(orphaned, &{to_string(&1.content_type), &1.name}))
  end

  # A definition's owner: a compiled content type XOR a dynamic one — or, for
  # an orphan, the stored name of a type that is gone.
  defp scope_key(%{type_definition_id: nil, content_type: content_type} = definition) do
    if FieldDefinition.orphaned?(definition),
      do: {:orphaned, to_string(content_type)},
      else: {:compiled, content_type}
  end

  defp scope_key(%{type_definition_id: id}), do: {:dynamic, id}

  # The same owner, as the type checkbox's value. An orphan's owner has no
  # checkbox, so its value matches none.
  defp scope_param(definition) do
    case scope_key(definition) do
      {:compiled, type} -> to_string(type)
      {:dynamic, id} -> "def:#{id}"
      {:orphaned, name} -> "orphaned:#{name}"
    end
  end

  defp group_heading({:compiled, type}, _dynamic_types), do: content_type_label(type)

  defp group_heading({:dynamic, id}, dynamic_types) do
    case Enum.find(dynamic_types, &(&1.definition.id == id)) do
      %{label: label} -> label
      # Field of an archived dynamic type — still listed, just tagged as such.
      _ -> gettext("Archived type")
    end
  end

  defp create_form(actor, org),
    do:
      FieldDefinition
      |> AshPhoenix.Form.for_create(:create, actor: actor, tenant: org, as: "field_definition")
      |> to_form()

  defp edit_form(id, actor, org) do
    CMS.get_field_definition!(id, actor: actor, tenant: org)
    |> AshPhoenix.Form.for_update(:update,
      actor: actor,
      tenant: org,
      as: "field_definition",
      # The add form is always on the page and also submits as
      # `field_definition[...]`; the same param names are fine, but without its
      # own id prefix both render `id="field_definition_label"` and every other
      # input twice, so labels and DOM patching target the add form's inputs.
      id: "edit_field_definition_#{id}"
    )
    |> to_form()
  end

  # Options are entered one-per-line (or comma-separated) in a textarea and
  # stored as a string array. Split, trim and drop blanks before they reach the
  # attribute. `scope` — one ticked type, or nil for the edit form, which never
  # moves a field — is unpacked into `content_type` XOR `type_definition_id`
  # here.
  #
  # The options and the default are only on the form for the types that use
  # them (#1819, #1820). Their inputs leave the page when another type is
  # picked, so whatever they held is dropped here rather than saved unseen: a
  # field that is no longer a select keeps no options, and a type with no
  # default keeps none. A select's default must still be one of its options.
  defp normalize(params, scope \\ nil) do
    type = params["field_type"]
    options = if type in [nil, "select"], do: parse_options(params["options"]), else: []

    default =
      cond do
        is_nil(type) -> params["default"]
        type not in @default_types -> nil
        type == "select" and params["default"] not in options -> nil
        true -> params["default"]
      end

    params
    |> Map.delete("scopes")
    |> Map.put("options", options)
    |> Map.put("default", default)
    |> unpack_targets()
    |> unpack_sources_limit()
    |> unpack_inverse()
    |> unpack_scope(scope)
  end

  # Emptying the other side's name removes the reverse list (R4), so its
  # machine name goes with it rather than standing alone.
  defp unpack_inverse(%{"inverse_label" => label} = params) when label in [nil, ""],
    do: Map.put(params, "inverse_name", nil)

  defp unpack_inverse(params), do: params

  # How many records may link to one target, asked as a choice (R1b, R9):
  # any number, only one, or a number the admin types. Only the last keeps
  # the typed `max_sources`.
  defp unpack_sources_limit(%{"sources_limit" => "any"} = params),
    do: Map.put(params, "max_sources", nil)

  defp unpack_sources_limit(%{"sources_limit" => "one"} = params),
    do: Map.put(params, "max_sources", "1")

  defp unpack_sources_limit(params), do: params

  # The "Links to" checkboxes post one list (`target_types[]`, with a leading
  # blank so unticking them all still posts). One ticked type is stored as the
  # documented single `target_type`; several as `target_types` (R2). Exactly
  # one of the two is ever set, which `Validations.ReferenceTarget` requires.
  # Absent — the field is not a reference, so no checkboxes rendered — leaves
  # both as they were.
  defp unpack_targets(%{"target_types" => picked} = params) do
    case picked |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() do
      [only] -> params |> Map.put("target_type", only) |> Map.put("target_types", [])
      types -> params |> Map.put("target_type", nil) |> Map.put("target_types", types)
    end
  end

  defp unpack_targets(params), do: params

  defp parse_options(options) when is_binary(options) do
    options
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_options(_options), do: []

  # Whether the options textarea applies: a `:select` field is the only type
  # that reads `options` (#1819).
  defp select?(form), do: to_string(form[:field_type].value) == "select"

  # Whether the default-value input applies (#1820).
  defp default?(form), do: to_string(form[:field_type].value) in @default_types

  # Whether the reference-target select applies to the form's current type.
  defp reference?(form), do: to_string(form[:field_type].value) == "reference"

  # Whether the compute-formula textarea applies (a `:computed` field, #429).
  defp computed?(form), do: to_string(form[:field_type].value) == "computed"

  defp unpack_scope(params, nil), do: params

  defp unpack_scope(params, "def:" <> id),
    do: params |> Map.put("type_definition_id", id) |> Map.put("content_type", nil)

  defp unpack_scope(params, type),
    do: params |> Map.put("content_type", type) |> Map.put("type_definition_id", nil)

  # Textarea value for the options field: the stored list joined by newlines.
  defp options_text(form) do
    case form[:options].value do
      list when is_list(list) -> Enum.join(list, "\n")
      str when is_binary(str) -> str
      _ -> ""
    end
  end

  # Core types humanize; plugin field types carry their own label.
  defp type_label(type) do
    case KilnCMS.CMS.FieldTypes.get(type) do
      nil -> Phoenix.Naming.humanize(type)
      module -> module.label()
    end
  end

  # What the selected type holds and what it is for, shown under the picker.
  # The form's value is an atom until the first change event and a string after
  # it; it is matched against the registered names rather than turned into an
  # atom, since it arrives from the client.
  defp type_description(value, field_types) do
    case Enum.find(field_types, &(to_string(&1) == to_string(value))) do
      nil -> nil
      type -> core_type_description(type) || plugin_type_description(type)
    end
  end

  defp core_type_description(:string),
    do: gettext("A single line of text. For short values like a subtitle, a SKU or a byline.")

  defp core_type_description(:text),
    do: gettext("Several lines of plain text. For notes, a summary or a postal address.")

  defp core_type_description(:integer),
    do: gettext("A whole number. For a count, a quantity, a rank or a year.")

  defp core_type_description(:float),
    do: gettext("A number that can have decimals. For a weight, a measurement or a score.")

  defp core_type_description(:boolean),
    do: gettext("A yes-or-no checkbox. For a flag such as “Featured” or “In stock”.")

  defp core_type_description(:date),
    do:
      gettext(
        "A calendar date with no time of day. For a deadline, a birthday or a release date."
      )

  defp core_type_description(:datetime),
    do: gettext("A date and a time of day. For when something opens, happened or expires.")

  defp core_type_description(:url),
    do: gettext("A web address. For a link to an external site, a source or a download.")

  defp core_type_description(:select),
    do:
      gettext(
        "One choice from a fixed list, which you type into Options below. For a size, a status or a category."
      )

  defp core_type_description(:media),
    do:
      gettext(
        "An image from the media library — one, or a whole gallery. For a hero image, a logo or a set of product shots."
      )

  defp core_type_description(:reference),
    do:
      gettext(
        "A link to other content — one record or a list, of the type you pick below. For a related article, an author or a parent product."
      )

  defp core_type_description(:user),
    do:
      gettext(
        "A person with an account on this site — an admin, editor or viewer. Always private: only editors and admins see it."
      )

  defp core_type_description(:group),
    do:
      gettext(
        "Structured rows, each with the same typed fields — one, or a list. For dosages with an amount and a unit, or a product's specifications."
      )

  defp core_type_description(:geolocation),
    do:
      gettext(
        "A point on a map: latitude, longitude and zoom. For a shop, a venue or where a photo was taken."
      )

  defp core_type_description(:computed),
    do:
      gettext(
        "Worked out from a formula on every save, so editors can't type into it. For a reading time or a code built from the title."
      )

  defp core_type_description(:datetime_range),
    do:
      gettext(
        "A start and an end, in a time zone, optionally all day. A content type with one of these is an event and gets a calendar feed."
      )

  defp core_type_description(:recurrence),
    do:
      gettext(
        "How often an event repeats, such as every Tuesday. Use it alongside a date & time range, which says when it starts."
      )

  defp core_type_description(_type), do: nil

  # Plugin types describe themselves; `description/0` is optional in the
  # contract, so a hand-rolled type without it shows nothing.
  defp plugin_type_description(type) do
    module = KilnCMS.CMS.FieldTypes.get(type)

    # `Code.ensure_loaded?` first, like every other probe of an optional
    # FieldType callback: `get/1` hands back an atom without loading it, and in
    # interactive mode a not-yet-loaded module answers `function_exported?`
    # with false — so the hint silently fell back to nothing.
    if module && Code.ensure_loaded?(module) && function_exported?(module, :description, 0),
      do: module.description()
  end

  defp content_type_label(type) do
    case ContentTypes.get(type) do
      %{label: label} -> label
      _ -> Phoenix.Naming.humanize(type)
    end
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  # `{label, name}` pairs: every content type on the site, compiled or dynamic.
  attr :target_types, :list, default: []
  attr :class, :string, default: "sm:col-span-2"

  # Which types a `:reference` field links to: one or several (R2). Ticking
  # one is the plain case; ticking more lets an editor connect records of any
  # of them, each remembering its own type.
  defp target_types_field(assigns) do
    picked = picked_targets(assigns.form)

    errors =
      if used_input?(assigns.form[:target_types]),
        do: assigns.form[:target_type].errors ++ assigns.form[:target_types].errors,
        else: []

    assigns =
      assigns
      |> assign(:picked, picked)
      |> assign(:errors, Enum.map(errors, &translate_error/1))

    ~H"""
    <fieldset
      :if={reference?(@form)}
      id={@id}
      class={@class}
      aria-describedby={"#{@id}-hint"}
    >
      <legend class="mb-1 block text-sm font-medium">{gettext("Links to")}</legend>
      <input type="hidden" name={"#{@form[:target_types].name}[]"} value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={{label, name} <- @target_types}
          for={"#{@id}-#{name}"}
          class={[
            "inline-flex cursor-pointer items-center gap-2 rounded-full border px-3 py-1 text-sm transition-colors",
            if(name in @picked,
              do: "border-primary bg-primary/5 text-base-content",
              else: "border-base-content/15 text-base-content/80 hover:border-base-content/30"
            )
          ]}
        >
          <input
            type="checkbox"
            id={"#{@id}-#{name}"}
            name={"#{@form[:target_types].name}[]"}
            value={name}
            checked={name in @picked}
            class="size-3.5 rounded border border-base-content/30 accent-primary"
          />
          {label}
        </label>
      </div>
      <p id={"#{@id}-hint"} class="mt-1 text-xs text-base-content/60">
        {targets_hint(length(@picked))}
      </p>
      <p :for={error <- @errors} class="mt-1 flex items-center gap-1.5 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-4" />{error}
      </p>
    </fieldset>
    """
  end

  defp targets_hint(count) when count > 1,
    do:
      gettext(
        "Editors can connect records of any ticked type. Each connection remembers which type it is."
      )

  defp targets_hint(_count),
    do: gettext("Editors choose records of this type. Tick more than one to allow several types.")

  # The type names a form currently links to, from whichever option holds them.
  defp picked_targets(form) do
    FieldDefinition.reference_targets(%{
      target_type: form[:target_type].value,
      target_types: List.wrap(form[:target_types].value) |> Enum.reject(&(&1 in [nil, ""]))
    })
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  # The definition as stored, on the edit form: turning an existing list
  # (a gallery, a list of references) back into a single item is lossy, and
  # the form says so before saving.
  attr :stored, :any, default: nil
  # `{label, name}` pairs, to name a reference's target type in the choices.
  attr :target_types, :list, default: []

  # Single image or a gallery, for a `:media` field — or one row or repeating
  # rows, for a `:group`, or one line or a list, for a `:string`, or one term
  # or several, for a `:select` (which then
  # also asks whether editors may add terms of their own, `allow_custom`) —
  # with the list's optional item bounds. A `:reference` field asks the same question from
  # both sides in `relationship_counts/1`; this keeps only the warning, shown
  # whenever a stored list is about to become a single item or another type.
  defp multiple_field(assigns) do
    type = list_type(assigns.form)
    multiple? = assigns.form[:multiple].value in [true, "true"]
    stored_type = list_type(assigns.stored)
    target = target_label(assigns.form, assigns.target_types)

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:multiple?, multiple?)
      |> assign(:target, target)
      |> assign(:choices, multiple_choices(type, target))
      |> assign(
        :narrowing,
        if(stored_type && (type != stored_type or not multiple?), do: stored_type)
      )

    # The warning outlives the toggle: retyping a list field to another type
    # narrows it just the same (`SyncFieldValues`), so it shows then too.
    ~H"""
    <div :if={@type in [:media, :group, :select, :string] || @narrowing} class="sm:col-span-2">
      <fieldset :if={@type in [:media, :group, :select, :string]}>
        <legend class="mb-1 block text-sm font-medium">{gettext("Holds")}</legend>
        <div class="grid gap-2 sm:grid-cols-2">
          <label
            :for={{value, title, hint, icon} <- @choices}
            for={"#{@id}-#{value}"}
            class={[
              "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
              if(to_string(@multiple?) == value,
                do: "border-primary bg-primary/5",
                else: "border-base-content/15 hover:border-base-content/30"
              )
            ]}
          >
            <input
              type="radio"
              id={"#{@id}-#{value}"}
              name={@form[:multiple].name}
              value={value}
              checked={to_string(@multiple?) == value}
              class="mt-0.5 size-4 accent-primary"
            />
            <span class="min-w-0">
              <span class="flex items-center gap-1.5 text-sm font-medium">
                <.icon name={icon} class="size-4 text-base-content/60" />
                {title}
              </span>
              <span class="mt-0.5 block text-xs text-base-content/60">{hint}</span>
            </span>
          </label>
        </div>
        <fieldset
          :if={@multiple?}
          id={"#{@id}-bounds"}
          class="mt-3 rounded-lg border border-base-content/10 bg-base-200/40 p-3"
        >
          <legend class="px-1 text-sm font-medium">
            {bounds_legend(@type, @target)}
            <span class="font-normal text-base-content/60">{gettext("(optional)")}</span>
          </legend>
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:min_items]}
              type="number"
              min="0"
              step="1"
              inputmode="numeric"
              label={gettext("Minimum")}
              placeholder={gettext("No minimum")}
            />
            <.input
              field={@form[:max_items]}
              type="number"
              min="1"
              step="1"
              inputmode="numeric"
              label={gettext("Maximum")}
              placeholder={gettext("No limit")}
            />
          </div>
          <p class="mt-2 text-xs text-base-content/60">
            {gettext(
              "Leave a box empty for no limit. Editors are told when they save outside these numbers; an empty field is fine unless Required is ticked."
            )}
          </p>
        </fieldset>
        <label
          :if={@type == :select and @multiple?}
          for={"#{@id}-allow-custom"}
          class="mt-3 flex items-start gap-2 text-sm"
        >
          <input type="hidden" name={@form[:allow_custom].name} value="false" />
          <input
            type="checkbox"
            id={"#{@id}-allow-custom"}
            name={@form[:allow_custom].name}
            value="true"
            checked={@form[:allow_custom].value in [true, "true"]}
            class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary"
          />
          <span>
            {gettext("Editors can add new terms")}
            <span class="block text-xs text-base-content/60">
              {gettext(
                "For a vocabulary that grows, like properties or keywords. The options become suggestions, and terms already used on this type are suggested too. A new term does not join the options."
              )}
            </span>
          </span>
        </label>
        <p
          :if={@type == :group}
          id={"#{@id}-sub-fields-hint"}
          class="mt-2 text-xs text-base-content/60"
        >
          {gettext(
            "Once the field is saved, add the fields each row holds — an amount, a unit — under it in the list below."
          )}
        </p>
      </fieldset>
      <p
        :if={@narrowing}
        id={"#{@id}-narrowing"}
        role="status"
        class="mt-2 flex items-start gap-1.5 text-xs text-warning-ink"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
        {narrowing_warning(@narrowing)}
      </p>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  # `{label, name}` pairs, to name a reference's target type in the wording.
  attr :target_types, :list, default: []

  # What deleting a target for good does to the records connected to it
  # (R5), asked from the target's side. How many records may connect to one
  # target (R1b) is asked with the other counts, in `relationship_counts/1`.
  defp target_rules_field(assigns) do
    assigns =
      assigns
      |> assign(:reference?, reference?(assigns.form))
      |> assign(:target, target_label(assigns.form, assigns.target_types))
      |> assign(:rule, to_string(assigns.form[:on_target_delete].value || "keep"))

    ~H"""
    <div :if={@reference?} id={@id} class="sm:col-span-2">
      <fieldset>
        <legend class="mb-1 block text-sm font-medium">{delete_legend(@target)}</legend>
        <div class="grid gap-2 sm:grid-cols-3">
          <label
            :for={{value, title, hint, icon} <- delete_choices()}
            for={"#{@id}-delete-#{value}"}
            class={[
              "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
              if(@rule == value,
                do: "border-primary bg-primary/5",
                else: "border-base-content/15 hover:border-base-content/30"
              )
            ]}
          >
            <input
              type="radio"
              id={"#{@id}-delete-#{value}"}
              name={@form[:on_target_delete].name}
              value={value}
              checked={@rule == value}
              class="mt-0.5 size-4 accent-primary"
            />
            <span class="min-w-0">
              <span class="flex items-center gap-1.5 text-sm font-medium">
                <.icon name={icon} class="size-4 text-base-content/60" />
                {title}
              </span>
              <span class="mt-0.5 block text-xs text-base-content/60">{hint}</span>
            </span>
          </label>
        </div>
        <p class="mt-1 text-xs text-base-content/60">
          {gettext(
            "Moving a record to the trash never changes anything here — restoring it brings everything back. These only apply when it is deleted for good."
          )}
        </p>
      </fieldset>
    </div>
    """
  end

  defp delete_legend(target) when is_binary(target),
    do: gettext("When a linked %{type} is deleted for good…", type: target)

  defp delete_legend(_target), do: gettext("When a linked record is deleted for good…")

  defp delete_choices do
    [
      {"keep", gettext("Leave the link"),
       gettext("Records keep pointing at it and show it as missing until someone edits them."),
       "hero-link"},
      {"clear", gettext("Remove it from them"),
       gettext(
         "It is taken out of every record that links to it, and published ones are updated."
       ), "hero-scissors"},
      {"restrict", gettext("Don't allow it"),
       gettext(
         "It can go to the trash, but can't be deleted for good while anything still links to it."
       ), "hero-lock-closed"}
    ]
  end

  # A repeating group's row bounds in the list, when it has any.
  defp rows_summary(%{min_items: min, max_items: max}) do
    case {min, max} do
      {nil, nil} -> gettext("Any number of rows.")
      {min, nil} -> ngettext("At least one row.", "At least %{count} rows.", min)
      {nil, max} -> ngettext("At most one row.", "At most %{count} rows.", max)
      {same, same} -> ngettext("Exactly one row.", "Exactly %{count} rows.", same)
      {min, max} -> gettext("Between %{min} and %{max} rows.", min: min, max: max)
    end
  end

  # The structured-data meaning in the list (#2044), when it has one.
  defp schema_org_summary(%{schema_org_property: :author}),
    do: gettext("Named as the page's authors in its structured data.")

  defp schema_org_summary(%{schema_org_property: :contributor}),
    do: gettext("Named as the page's contributors in its structured data.")

  defp schema_org_summary(_definition), do: ""

  # The delete rule in the list, after the summary, when it is not the
  # default.
  defp target_rules_summary(definition, target_types) do
    target =
      definition
      |> FieldDefinition.reference_targets()
      |> Enum.map(&type_label_for(target_types, &1))
      |> types_phrase() || gettext("record")

    case definition.on_target_delete do
      :clear ->
        gettext(
          "%{type} records deleted for good are removed from the records linking to them.",
          type: target
        )

      :restrict ->
        gettext("%{type} records can't be deleted for good while anything links to them.",
          type: target
        )

      _keep ->
        ""
    end
  end

  # One plain line under a reference field in the list: the relationship read
  # from both sides, so an admin can scan the fields without opening each one.
  defp reference_summary(definition, target_types, dynamic_types) do
    relationship_sentence(%{
      source: group_heading(scope_key(definition), dynamic_types),
      target:
        definition
        |> FieldDefinition.reference_targets()
        |> Enum.map(&type_label_for(target_types, &1))
        |> types_phrase(),
      multiple?: definition.multiple,
      min: definition.min_items,
      max: definition.max_items,
      max_sources: definition.max_sources,
      inverse: definition.inverse_label
    })
  end

  # The same sentence for a form being filled in, so the admin reads what
  # they are about to save.
  defp form_sentence(form, source, target_types) do
    relationship_sentence(%{
      source: source,
      target: target_label(form, target_types),
      multiple?: form[:multiple].value in [true, "true"],
      min: count_value(form[:min_items].value),
      max: count_value(form[:max_items].value),
      max_sources: count_value(form[:max_sources].value),
      inverse: form[:inverse_label].value
    })
  end

  # "Each Recipe connects several Ingredient records (up to 5); each
  # Ingredient can be linked from at most 2 Recipe records." — the stored
  # options (`multiple`, `min_items`/`max_items`, `max_sources`,
  # `inverse_label`) in the words of Toolset's relationship wizard.
  defp relationship_sentence(%{} = parts) do
    source = parts.source || gettext("record")
    target = parts.target || gettext("linked record")

    this_side =
      if parts.multiple?,
        do:
          gettext("Each %{source} connects several %{type} records (%{count})",
            source: source,
            type: target,
            count: item_bounds_label(parts.min, parts.max)
          ),
        else: gettext("Each %{source} connects one %{type}", source: source, type: target)

    other_side =
      case parts.max_sources do
        nil ->
          gettext("each %{type} can be linked from any number of %{source} records",
            source: source,
            type: target
          )

        count ->
          ngettext(
            "each %{type} can be linked from only one %{source}",
            "each %{type} can be linked from at most %{count} %{source} records",
            count,
            source: source,
            type: target
          )
      end

    sentence =
      gettext("%{this_side}; %{other_side}.", this_side: this_side, other_side: other_side)

    case parts.inverse do
      label when is_binary(label) and label != "" ->
        gettext("%{sentence} Each %{type} lists them as “%{label}”.",
          sentence: sentence,
          type: target,
          label: label
        )

      _none ->
        sentence
    end
  end

  defp count_value(value) when is_integer(value), do: value

  defp count_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> count
      _other -> nil
    end
  end

  defp count_value(_value), do: nil

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :inverse_id, :string, required: true
  attr :target_types, :list, default: []
  attr :source, :string, default: nil
  # The add form fills the machine name from the label; the edit form keeps it.
  attr :name?, :boolean, default: false

  # Step 3 of a relationship: what each side calls it. This side's label is
  # the field's; the other side's is the reverse list (R4).
  defp relationship_names(assigns) do
    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-heading"} class="space-y-3 sm:col-span-2">
      <.step_heading number={3} id={"#{@id}-heading"}>
        {gettext("What each side calls it")}
      </.step_heading>
      <div class="grid items-start gap-3 lg:grid-cols-2">
        <fieldset class="rounded-lg border border-base-content/10 bg-base-200/40 p-3">
          <legend class="px-1 text-sm font-medium">
            {gettext("What %{type} calls this", type: @source || gettext("the record"))}
          </legend>
          <div class="grid gap-3">
            <.input
              field={@form[:label]}
              label={gettext("Label")}
              placeholder={gettext("Ingredients")}
            />
            <.input
              :if={@name?}
              field={@form[:name]}
              label={gettext("Machine name")}
              placeholder="ingredients"
              hint={gettext("Filled in from the label until you change it.")}
            />
          </div>
        </fieldset>
        <.inverse_field form={@form} id={@inverse_id} target_types={@target_types} />
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :source, :string, default: nil
  attr :target_types, :list, default: []

  # What the admin is about to save, as the field list will say it.
  defp relationship_summary(assigns) do
    ~H"""
    <p
      :if={reference?(@form)}
      id={@id}
      role="status"
      class="rounded-lg bg-base-200/60 p-3 text-sm sm:col-span-2"
    >
      <span class="font-medium">{gettext("In one sentence:")}</span>
      {form_sentence(@form, @source, @target_types)}
    </p>
    """
  end

  # The add form's source side as words: the ticked types, "Recipe or Post".
  defp scopes_label(scopes, content_types, dynamic_types) do
    labels =
      Enum.flat_map(scopes, fn
        "def:" <> id ->
          for dt <- dynamic_types, dt.definition.id == id, do: dt.label

        type ->
          for ct <- content_types, to_string(ct.type) == type, do: ct.label
      end)

    types_phrase(labels)
  end

  # The value form's type picker: every type but `:reference`, which is
  # "A relationship" now.
  defp value_type_options(field_types),
    do: for(type <- field_types, type != :reference, do: {type_label(type), type})

  # The step heading over the delete rule, in the relationship form.
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :target_types, :list, default: []

  defp relationship_rules(assigns) do
    ~H"""
    <section aria-labelledby={"#{@id}-heading"} class="space-y-3 sm:col-span-2">
      <.step_heading number={4} id={"#{@id}-heading"}>
        {gettext("When one is deleted")}
      </.step_heading>
      <.target_rules_field form={@form} id={@id} target_types={@target_types} />
    </section>
    <section aria-labelledby={"#{@id}-meaning-heading"} class="space-y-3 sm:col-span-2">
      <.step_heading number={5} id={"#{@id}-meaning-heading"}>
        {gettext("What they are to the page")}
      </.step_heading>
      <.input
        field={@form[:schema_org_property]}
        id={"#{@id}-schema-org-property"}
        type="select"
        label={gettext("For search engines, the linked records are")}
        prompt={gettext("Nothing in particular")}
        options={schema_org_property_options()}
        hint={
          gettext(
            "Pick Authors for a byline: each linked record is then named as an author of the page in its structured data, and in the By line on the site's own pages."
          )
        }
      />
    </section>
    """
  end

  # The schema.org meaning of a reference's targets (#2044), as the select
  # offers it.
  defp schema_org_property_options do
    [{gettext("Authors"), "author"}, {gettext("Contributors"), "contributor"}]
  end

  attr :form, :any, required: true
  attr :id, :string, required: true

  # The first question on both forms (R9): a value, or a connection to other
  # records. Toolset's relationship wizard starts the same way, so an admin
  # who means "recipes have ingredients" never has to know that is a
  # reference field.
  defp kind_field(assigns) do
    assigns =
      assign(assigns, :kind, if(reference?(assigns.form), do: "relationship", else: "value"))

    ~H"""
    <fieldset id={@id} class="sm:col-span-2">
      <legend class="mb-1 block text-sm font-medium">{gettext("This field holds")}</legend>
      <div class="grid gap-2 sm:grid-cols-2">
        <label
          :for={{value, title, hint, icon} <- kind_choices()}
          for={"#{@id}-#{value}"}
          class={[
            "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
            if(@kind == value,
              do: "border-primary bg-primary/5",
              else: "border-base-content/15 hover:border-base-content/30"
            )
          ]}
        >
          <input
            type="radio"
            id={"#{@id}-#{value}"}
            name={"#{@form.name}[kind]"}
            value={value}
            checked={@kind == value}
            class="mt-0.5 size-4 accent-primary"
          />
          <span class="min-w-0">
            <span class="flex items-center gap-1.5 text-sm font-medium">
              <.icon name={icon} class="size-4 text-base-content/60" />
              {title}
            </span>
            <span class="mt-0.5 block text-xs text-base-content/60">{hint}</span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp kind_choices do
    [
      {"value", gettext("A value"),
       gettext("Text, a number, a date, an image — typed or picked on each record."),
       "hero-pencil-square"},
      {"relationship", gettext("A relationship"),
       gettext(
         "Connects each record to records of another type — a recipe's ingredients, a post's author."
       ), "hero-arrows-right-left"}
    ]
  end

  attr :number, :integer, required: true
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp step_heading(assigns) do
    ~H"""
    <h3 id={@id} class="flex items-center gap-2 text-sm font-semibold">
      <span
        aria-hidden="true"
        class="inline-flex size-5 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-semibold text-primary-ink"
      >
        {@number}
      </span>
      {render_slot(@inner_block)}
    </h3>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :target_types, :list, default: []
  # The add form picks the source types (`scopes`, the same checkboxes the
  # value form shows as "Content types"); the edit form names its one type.
  attr :content_types, :list, default: []
  attr :dynamic_types, :list, default: []
  attr :scopes, :list, default: nil
  attr :scope_error, :string, default: nil
  attr :source, :string, default: nil
  attr :targets_id, :string, required: true

  # Step 1 of a relationship: both sides, named as a sentence — "Recipe links
  # to Ingredient" — with as many target types as the admin ticks (R2).
  defp relationship_sides(assigns) do
    assigns = assign(assigns, :target, target_label(assigns.form, assigns.target_types))

    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-heading"} class="space-y-3 sm:col-span-2">
      <.step_heading number={1} id={"#{@id}-heading"}>
        {gettext("Which records connect")}
      </.step_heading>
      <div class="grid items-start gap-3 rounded-lg border border-base-content/10 p-3 sm:grid-cols-[1fr_auto_1fr]">
        <fieldset id={"#{@id}-source"}>
          <legend class="mb-1 block text-sm font-medium">{gettext("From")}</legend>
          <div :if={@scopes} class="flex flex-wrap gap-2">
            <input type="hidden" name="field_definition[scopes][]" value="" />
            <.scope_checkbox
              :for={ct <- @content_types}
              value={to_string(ct.type)}
              label={ct.label}
              scopes={@scopes}
              chip
            />
            <.scope_checkbox
              :for={dt <- @dynamic_types}
              value={"def:#{dt.definition.id}"}
              label={dt.label}
              scopes={@scopes}
              chip
            />
          </div>
          <p :if={!@scopes} class="text-sm">
            <span class="inline-flex items-center rounded-full border border-primary bg-primary/5 px-3 py-1">
              {@source}
            </span>
          </p>
          <p :if={@scopes} class="mt-1 text-xs text-base-content/60">
            {gettext("The records this field is on. Each ticked type gets its own copy.")}
          </p>
          <p :if={@scope_error} class="mt-1.5 flex items-center gap-2 text-sm text-error">
            <.icon name="hero-exclamation-circle" class="size-5" />
            {@scope_error}
          </p>
        </fieldset>
        <.icon
          name="hero-arrow-right"
          class="mx-auto hidden size-5 self-center text-base-content/40 sm:block"
        />
        <.target_types_field
          form={@form}
          id={@targets_id}
          target_types={@target_types}
          class=""
        />
      </div>
      <p id={"#{@id}-sentence"} class="text-sm text-base-content/80">
        <%= if @source && @target do %>
          {gettext("%{source} links to %{type}.", source: @source, type: @target)}
        <% else %>
          {gettext("Tick a type on each side.")}
        <% end %>
      </p>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  # Ids kept from the 1.5 form, so its radios and the bounds keep them.
  attr :multiple_id, :string, required: true
  attr :target_types, :list, default: []
  attr :source, :string, default: nil

  # Step 2 of a relationship: how many on each side, Toolset-style. This side
  # is `multiple` with its optional item bounds; the other side is
  # `max_sources` (R1b), as any number, only one, or a typed limit.
  defp relationship_counts(assigns) do
    target = target_label(assigns.form, assigns.target_types)
    multiple? = assigns.form[:multiple].value in [true, "true"]

    assigns =
      assigns
      |> assign(:target, target)
      |> assign(:multiple?, multiple?)
      |> assign(:choices, multiple_choices(:reference, target))
      |> assign(:limit, sources_limit(assigns.form))
      |> assign(:limit_choices, sources_choices(assigns.source))

    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-heading"} class="space-y-3 sm:col-span-2">
      <.step_heading number={2} id={"#{@id}-heading"}>
        {gettext("How many on each side")}
      </.step_heading>
      <div class="grid gap-3 lg:grid-cols-2">
        <fieldset class="rounded-lg border border-base-content/10 p-3">
          <legend class="px-1 text-sm font-medium">
            {gettext("Each %{source} connects…", source: @source || gettext("record"))}
          </legend>
          <div class="grid gap-2">
            <label
              :for={{value, title, hint, icon} <- @choices}
              for={"#{@multiple_id}-#{value}"}
              class={[
                "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
                if(to_string(@multiple?) == value,
                  do: "border-primary bg-primary/5",
                  else: "border-base-content/15 hover:border-base-content/30"
                )
              ]}
            >
              <input
                type="radio"
                id={"#{@multiple_id}-#{value}"}
                name={@form[:multiple].name}
                value={value}
                checked={to_string(@multiple?) == value}
                class="mt-0.5 size-4 accent-primary"
              />
              <span class="min-w-0">
                <span class="flex items-center gap-1.5 text-sm font-medium">
                  <.icon name={icon} class="size-4 text-base-content/60" />
                  {title}
                </span>
                <span class="mt-0.5 block text-xs text-base-content/60">{hint}</span>
              </span>
            </label>
          </div>
          <fieldset
            :if={@multiple?}
            id={"#{@multiple_id}-bounds"}
            class="mt-3 rounded-lg border border-base-content/10 bg-base-200/40 p-3"
          >
            <legend class="px-1 text-sm font-medium">
              {bounds_legend(:reference, @target)}
              <span class="font-normal text-base-content/60">{gettext("(optional)")}</span>
            </legend>
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:min_items]}
                type="number"
                min="0"
                step="1"
                inputmode="numeric"
                label={gettext("Minimum")}
                placeholder={gettext("No minimum")}
              />
              <.input
                field={@form[:max_items]}
                type="number"
                min="1"
                step="1"
                inputmode="numeric"
                label={gettext("Maximum")}
                placeholder={gettext("No limit")}
              />
            </div>
            <p class="mt-2 text-xs text-base-content/60">
              {gettext(
                "Leave a box empty for no limit. Editors are told when they save outside these numbers; an empty field is fine unless Required is ticked."
              )}
            </p>
          </fieldset>
        </fieldset>

        <fieldset class="rounded-lg border border-base-content/10 p-3">
          <legend class="px-1 text-sm font-medium">
            {gettext("Each %{type} can be linked from…", type: @target || gettext("linked record"))}
          </legend>
          <div class="grid gap-2">
            <label
              :for={{value, title, hint, icon} <- @limit_choices}
              for={"#{@id}-sources-#{value}"}
              class={[
                "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
                if(@limit == value,
                  do: "border-primary bg-primary/5",
                  else: "border-base-content/15 hover:border-base-content/30"
                )
              ]}
            >
              <input
                type="radio"
                id={"#{@id}-sources-#{value}"}
                name={"#{@form.name}[sources_limit]"}
                value={value}
                checked={@limit == value}
                class="mt-0.5 size-4 accent-primary"
              />
              <span class="min-w-0">
                <span class="flex items-center gap-1.5 text-sm font-medium">
                  <.icon name={icon} class="size-4 text-base-content/60" />
                  {title}
                </span>
                <span class="mt-0.5 block text-xs text-base-content/60">{hint}</span>
              </span>
            </label>
          </div>
          <div :if={@limit == "some"} id={"#{@id}-sources-limit"} class="mt-3 max-w-xs">
            <.input
              field={@form[:max_sources]}
              type="number"
              min="1"
              step="1"
              inputmode="numeric"
              label={gettext("At most")}
              placeholder={gettext("No limit")}
            />
          </div>
          <p class="mt-2 text-xs text-base-content/60">
            {gettext(
              "Limit it when what you link to is scarce — a seat, a slot, a featured place. Once a record is full, editors see it as full in the picker. Lowering the number later never removes links that already exist."
            )}
          </p>
        </fieldset>
      </div>
    </section>
    """
  end

  # Which of the three choices the form is on: the one last picked, else the
  # one the stored `max_sources` reads as.
  defp sources_limit(form) do
    case form.params["sources_limit"] do
      limit when limit in ["any", "one", "some"] ->
        limit

      _unpicked ->
        case count_value(form[:max_sources].value) do
          nil -> "any"
          1 -> "one"
          _count -> "some"
        end
    end
  end

  defp sources_choices(source) do
    source = source || gettext("record")

    [
      {"any", gettext("Any number of %{source} records", source: source),
       gettext("Many-to-many: an ingredient goes in every recipe that uses it."),
       "hero-squares-plus"},
      {"one", gettext("Only one %{source}", source: source),
       gettext("One-to-many: a chapter belongs to a single book."), "hero-link"},
      {"some", gettext("A limited number"),
       gettext("At most the number you set — three speakers per panel."), "hero-hashtag"}
    ]
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :target_types, :list, default: []

  # The other side of a reference (R4), in the voice of the rest of the
  # form: what the linked-to record calls the records that link to it. Its
  # machine name fills in from the label unless an admin changes it.
  defp inverse_field(assigns) do
    assigns =
      assign(
        assigns,
        :target,
        target_label(assigns.form, assigns.target_types) || gettext("the linked record")
      )

    ~H"""
    <fieldset
      :if={reference?(@form)}
      id={@id}
      class="rounded-lg border border-base-content/10 bg-base-200/40 p-3"
    >
      <legend class="px-1 text-sm font-medium">
        {gettext("What %{type} calls this", type: @target)}
        <span class="font-normal text-base-content/60">{gettext("(optional)")}</span>
      </legend>
      <div class="grid gap-3">
        <.input
          field={@form[:inverse_label]}
          label={gettext("Name on the other side")}
          placeholder={gettext("Recipes using this ingredient")}
        />
        <.input
          field={@form[:inverse_name]}
          label={gettext("Machine name")}
          placeholder="used_in_recipes"
          hint={gettext("Filled in from the name if left empty. The API uses it.")}
        />
      </div>
      <p class="mt-2 text-xs text-base-content/60">
        {gettext(
          "Give it a name and every %{type} shows a list of the records that connect to it through this field. Leave it empty for no list.",
          type: @target
        )}
      </p>
    </fieldset>
    """
  end

  defp item_bounds_label(nil, nil), do: gettext("any number")
  defp item_bounds_label(min, nil), do: gettext("at least %{min}", min: min)
  defp item_bounds_label(nil, max), do: gettext("up to %{max}", max: max)
  defp item_bounds_label(same, same), do: gettext("exactly %{count}", count: same)
  defp item_bounds_label(min, max), do: gettext("%{min} to %{max}", min: min, max: max)

  # The list-capable type a form or a stored definition is, or nil.
  defp list_type(nil), do: nil

  defp list_type(%Phoenix.HTML.Form{} = form) do
    case to_string(form[:field_type].value) do
      "media" -> :media
      "reference" -> :reference
      "group" -> :group
      "select" -> :select
      "string" -> :string
      _other -> nil
    end
  end

  defp list_type(%{field_type: type, multiple: true})
       when type in [:media, :reference, :group, :select, :string],
       do: type

  defp list_type(_stored), do: nil

  # The reference's target types as an admin reads them ("Page", "Page or
  # Post"), once picked.
  defp target_label(form, target_types) do
    case picked_targets(form) do
      [] -> nil
      names -> names |> Enum.map(&type_label_for(target_types, &1)) |> types_phrase()
    end
  end

  defp types_phrase([]), do: nil
  defp types_phrase([only]), do: only

  defp types_phrase(labels) do
    {init, [last]} = Enum.split(labels, -1)
    gettext("%{types} or %{last}", types: Enum.join(init, ", "), last: last)
  end

  defp type_label_for(target_types, name) do
    case List.keyfind(target_types, name, 1) do
      {label, _name} -> label
      nil -> name
    end
  end

  defp bounds_legend(:reference, target) when is_binary(target),
    do: gettext("How many %{type} records can be connected", type: target)

  defp bounds_legend(:media, _target), do: gettext("How many images")
  defp bounds_legend(:group, _target), do: gettext("How many rows")
  defp bounds_legend(:select, _target), do: gettext("How many terms")
  defp bounds_legend(:string, _target), do: gettext("How many items")
  defp bounds_legend(_type, _target), do: gettext("How many items")

  defp multiple_choices(:media, _target) do
    [
      {"false", gettext("A single item"), gettext("One image — a hero, a logo, a portrait."),
       "hero-photo"},
      {"true", gettext("A gallery"),
       gettext("Several images, in the order the editor arranges them."), "hero-squares-2x2"}
    ]
  end

  defp multiple_choices(:group, _target) do
    [
      {"false", gettext("One set of values"),
       gettext("A single row — a product's specifications, a venue's address."),
       "hero-rectangle-group"},
      {"true", gettext("Repeating rows"),
       gettext(
         "As many rows as the editor adds, in the order they arrange them — dosages, steps."
       ), "hero-table-cells"}
    ]
  end

  defp multiple_choices(:string, _target) do
    [
      {"false", gettext("One line"), gettext("A single short text — a name, a code."),
       "hero-minus"},
      {"true", gettext("A list"),
       gettext(
         "As many phrases as the editor adds, each free text, in their order — symptoms, synonyms."
       ), "hero-list-bullet"}
    ]
  end

  defp multiple_choices(:select, _target) do
    [
      {"false", gettext("One choice"), gettext("A single option — a status, a size."),
       "hero-chevron-up-down"},
      {"true", gettext("Several terms"),
       gettext("As many as the editor picks, as tags, in the order they arrange them."),
       "hero-tag"}
    ]
  end

  # Named after what the field connects, as a relationship ("One Page",
  # "Several Pages") rather than as a data shape, once the target is picked.
  defp multiple_choices(_reference, target) when is_binary(target) do
    [
      {"false", gettext("One %{type}", type: target),
       gettext("Editors connect a single %{type} — an author, a parent product.", type: target),
       "hero-link"},
      {"true", gettext("Several %{type} records", type: target),
       gettext("Editors connect as many as you allow, in the order they choose."),
       "hero-queue-list"}
    ]
  end

  defp multiple_choices(_reference, _target) do
    [
      {"false", gettext("A single item"), gettext("One record — an author, a parent product."),
       "hero-link"},
      {"true", gettext("A list"),
       gettext("Several records, in the order the editor arranges them."), "hero-queue-list"}
    ]
  end

  defp narrowing_warning(:media),
    do:
      gettext(
        "Saving keeps only the first image of each gallery already filled in. The others are removed from the content, not from the media library."
      )

  defp narrowing_warning(:group),
    do:
      gettext(
        "Saving keeps only the first row of each list already filled in. The other rows are removed from the content."
      )

  defp narrowing_warning(:string),
    do:
      gettext(
        "Saving keeps only the first item of each list already filled in. The other items are removed from the content."
      )

  defp narrowing_warning(:select),
    do:
      gettext(
        "Saving keeps only the first term of each list already filled in. The other terms are removed from the content."
      )

  defp narrowing_warning(:reference),
    do:
      gettext(
        "Saving keeps only the first item of each list already filled in. The others are unlinked from the content; the records themselves are not touched."
      )

  attr :form, :any, required: true
  attr :id, :string, required: true

  # How a `:text` field is edited (`format`): with the formatting toolbar, or
  # as plain text. Shown only for that type; the value is stored on every
  # definition and read only by a `:text` one.
  defp text_format_field(assigns) do
    assigns = assign(assigns, :format, to_string(assigns.form[:format].value || "rich"))

    ~H"""
    <fieldset :if={to_string(@form[:field_type].value) == "text"} class="sm:col-span-2">
      <legend class="mb-1 block text-sm font-medium">{gettext("Editing")}</legend>
      <div class="grid gap-2 sm:grid-cols-2">
        <label
          :for={{value, title, hint, icon} <- text_format_choices()}
          for={"#{@id}-#{value}"}
          class={[
            "flex cursor-pointer items-start gap-3 rounded-lg border p-3 transition-colors",
            if(@format == value,
              do: "border-primary bg-primary/5",
              else: "border-base-content/15 hover:border-base-content/30"
            )
          ]}
        >
          <input
            type="radio"
            id={"#{@id}-#{value}"}
            name={@form[:format].name}
            value={value}
            checked={@format == value}
            class="mt-0.5 size-4 accent-primary"
          />
          <span class="min-w-0">
            <span class="flex items-center gap-1.5 text-sm font-medium">
              <.icon name={icon} class="size-4 text-base-content/60" />
              {title}
            </span>
            <span class="mt-0.5 block text-xs text-base-content/60">{hint}</span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp text_format_choices do
    [
      {"rich", gettext("Formatted text"),
       gettext("A toolbar for bold, italic, links and lists. Stored as HTML."), "hero-bold"},
      {"plain", gettext("Plain text"),
       gettext("A plain box, stored exactly as typed — for a note or a code."),
       "hero-bars-3-bottom-left"}
    ]
  end

  attr :form, :any, required: true
  attr :id, :string, required: true

  # Whether delivery carries a plain-text rendition beside a `:text` field's
  # value (`deliver_plain`). Shown only for that type: on any other, nothing
  # is submitted and `Changes.ClearDeliverPlain` drops a stored `true`.
  defp deliver_plain_field(assigns) do
    ~H"""
    <label
      :if={to_string(@form[:field_type].value) == "text"}
      for={@id}
      class="flex items-start gap-2 self-end text-sm"
    >
      <input type="hidden" name={@form[:deliver_plain].name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@form[:deliver_plain].name}
        value="true"
        checked={@form[:deliver_plain].value in [true, "true"]}
        class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary"
      />
      <span>
        {gettext("Also deliver as plain text")}
        <span class="block text-xs text-base-content/60">
          {gettext(
            "APIs add a copy with HTML tags removed under custom_fields_plain, for apps that cannot render HTML."
          )}
        </span>
      </span>
    </label>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true

  # Whether the value is for editors and admins only (#2044,
  # `KilnCMS.CMS.PrivateFields`). Offered for the types that can be private;
  # a `:user` field always is, so it says so instead of asking.
  defp private_field(assigns) do
    assigns = assign(assigns, :type, to_string(assigns.form[:field_type].value))

    ~H"""
    <p :if={@type == "user"} id={@id} class="flex items-start gap-2 self-end text-sm">
      <.icon name="hero-lock-closed" class="mt-0.5 size-4 text-base-content/60" />
      <span>
        {gettext("Private")}
        <span class="block text-xs text-base-content/60">
          {gettext("A person field is always private: only editors and admins see it.")}
        </span>
      </span>
    </p>
    <label
      :if={@type != "user" and @type in private_types()}
      for={@id}
      class="flex items-start gap-2 self-end text-sm"
    >
      <input type="hidden" name={@form[:private].name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@form[:private].name}
        value="true"
        checked={@form[:private].value in [true, "true"]}
        class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary"
      />
      <span>
        {gettext("Private")}
        <span class="block text-xs text-base-content/60">
          {gettext(
            "Only editors and admins see the value. It is left out of the site, every API, feeds and search."
          )}
        </span>
      </span>
    </label>
    """
  end

  defp private_types, do: Enum.map(KilnCMS.CMS.PrivateFields.types(), &to_string/1)

  attr :form, :any, required: true
  attr :id, :string, required: true

  # The choices of a `:select` field, shown only for that type (#1819).
  defp options_field(assigns) do
    ~H"""
    <div :if={select?(@form)} class="sm:col-span-2">
      <label for={@id} class="mb-1 block text-sm font-medium">
        {gettext("Options")}
      </label>
      <textarea
        id={@id}
        name={@form[:options].name}
        rows="3"
        class="field-input"
      >{options_text(@form)}</textarea>
      <p class="mt-1 text-xs text-base-content/60">
        {options_hint(@form)}
      </p>
    </div>
    """
  end

  defp options_hint(form) do
    cond do
      form[:allow_custom].value in [true, "true"] and form[:multiple].value in [true, "true"] ->
        gettext(
          "One per line. Suggested to editors, who can also add their own; may be left empty."
        )

      form[:multiple].value in [true, "true"] ->
        gettext("One choice per line. Editors pick any number of these.")

      true ->
        gettext("One choice per line. Editors pick one of these.")
    end
  end

  attr :form, :any, required: true

  # The default value, for the types that take one (#1820), in the input that
  # fits the type: a checkbox for yes-or-no, a number box for numbers, a date
  # picker for dates, and one of the options for a select.
  defp default_field(assigns) do
    assigns =
      assigns
      |> assign(:type, to_string(assigns.form[:field_type].value))
      |> assign(:hint, gettext("Used when an editor leaves this field empty."))

    ~H"""
    <div :if={default?(@form)} class={@type == "boolean" && "self-end"}>
      <label :if={@type == "boolean"} class="flex items-center gap-2 text-sm">
        <input type="hidden" name={@form[:default].name} value="" />
        <input
          type="checkbox"
          id={@form[:default].id}
          name={@form[:default].name}
          value="true"
          checked={@form[:default].value in [true, "true"]}
          class="size-4 rounded border border-base-content/30 accent-primary"
        />
        {gettext("Ticked by default")}
      </label>
      <.input
        :if={@type == "select"}
        field={@form[:default]}
        type="select"
        label={gettext("Default value")}
        options={parse_options(options_text(@form))}
        prompt={gettext("— No default —")}
        hint={@hint}
      />
      <.input
        :if={@type not in ["boolean", "select"]}
        field={@form[:default]}
        type={default_input_type(@type)}
        step={default_input_step(@type)}
        label={gettext("Default value")}
        hint={@hint}
      />
    </div>
    """
  end

  defp default_input_type("integer"), do: "number"
  defp default_input_type("float"), do: "number"
  defp default_input_type("date"), do: "date"
  defp default_input_type("datetime"), do: "datetime-local"
  defp default_input_type("url"), do: "url"
  defp default_input_type(_type), do: "text"

  defp default_input_step("integer"), do: "1"
  defp default_input_step("float"), do: "any"
  defp default_input_step(_type), do: nil

  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :scopes, :list, required: true
  attr :chip, :boolean, default: false

  defp scope_checkbox(assigns) do
    ~H"""
    <label class={[
      "flex items-center gap-2 text-sm",
      @chip &&
        [
          "cursor-pointer rounded-full border px-3 py-1 transition-colors",
          if(@value in @scopes,
            do: "border-primary bg-primary/5 text-base-content",
            else: "border-base-content/15 text-base-content/80 hover:border-base-content/30"
          )
        ]
    ]}>
      <input
        type="checkbox"
        name="field_definition[scopes][]"
        value={@value}
        checked={@value in @scopes}
        class="size-4 rounded border border-base-content/30 accent-primary"
      />
      {@label}
    </label>
    """
  end

  # A DOM-safe id for one type's list.
  defp group_dom_id({:compiled, type}), do: "type-#{type}"
  defp group_dom_id({:dynamic, id}), do: "def-#{id}"

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
      active={:fields}
    >
      <div class="space-y-8">
        <div>
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:fields}
          />
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
            class="card card-pad grid gap-4 sm:grid-cols-2"
          >
            <.kind_field form={@form} id="new-field-kind" />
            <%= if reference?(@form) do %>
              <input type="hidden" name={@form[:field_type].name} value="reference" />
              <.relationship_sides
                form={@form}
                id="new-field-sides"
                targets_id="new-field-targets"
                target_types={@target_types}
                content_types={@content_types}
                dynamic_types={@dynamic_types}
                scopes={@scopes}
                scope_error={@scope_error}
                source={scopes_label(@scopes, @content_types, @dynamic_types)}
              />
              <.relationship_counts
                form={@form}
                id="new-field-counts"
                multiple_id="new-field-multiple"
                target_types={@target_types}
                source={scopes_label(@scopes, @content_types, @dynamic_types)}
              />
              <.relationship_names
                form={@form}
                id="new-field-names"
                inverse_id="new-field-inverse"
                target_types={@target_types}
                source={scopes_label(@scopes, @content_types, @dynamic_types)}
                name?
              />
              <.relationship_rules form={@form} id="new-field-rules" target_types={@target_types} />
            <% else %>
              <fieldset class="sm:col-span-2">
                <legend class="mb-1 block text-sm font-medium">
                  {gettext("Content types")}
                </legend>
                <p class="mb-2 text-xs text-base-content/60">
                  {gettext(
                    "Tick every type that should carry this field. Each gets its own copy under the same machine name, which you can then change on its own."
                  )}
                </p>
                <input type="hidden" name="field_definition[scopes][]" value="" />
                <div class="grid gap-x-4 gap-y-1 sm:grid-cols-3">
                  <.scope_checkbox
                    :for={ct <- @content_types}
                    value={to_string(ct.type)}
                    label={ct.label}
                    scopes={@scopes}
                  />
                  <.scope_checkbox
                    :for={dt <- @dynamic_types}
                    value={"def:#{dt.definition.id}"}
                    label={dt.label}
                    scopes={@scopes}
                  />
                </div>
                <p :if={@scope_error} class="mt-1.5 flex items-center gap-2 text-sm text-error">
                  <.icon name="hero-exclamation-circle" class="size-5" />
                  {@scope_error}
                </p>
              </fieldset>
              <.input field={@form[:label]} label={gettext("Label")} placeholder="Shoe size" />
              <.input
                field={@form[:name]}
                label={gettext("Machine name")}
                placeholder="shoe_size"
                hint={gettext("Filled in from the label until you change it.")}
              />
              <.input
                field={@form[:field_type]}
                type="select"
                label={gettext("Field type")}
                options={value_type_options(@field_types)}
                hint={type_description(@form[:field_type].value, @field_types)}
              />
              <.compute_builder
                :if={computed?(@form)}
                form={@form}
                builder={@builder}
                ctx={@builder_ctx}
                recipes={@recipes}
                categories={@function_categories}
                id="new-field"
              />
              <.multiple_field form={@form} id="new-field-multiple" target_types={@target_types} />
            <% end %>
            <.input field={@form[:help_text]} label={gettext("Help text")} />
            <.localization_input field={@form[:localization]} />
            <.options_field form={@form} id="new-field-options" />
            <.default_field form={@form} />
            <.text_format_field form={@form} id="new-field-format" />
            <.deliver_plain_field form={@form} id="new-field-deliver-plain" />
            <.private_field form={@form} id="new-field-private" />
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
            <label class="flex items-center gap-2 self-end text-sm">
              <input type="hidden" name="field_definition[names_record]" value="false" />
              <input
                type="checkbox"
                name="field_definition[names_record]"
                value="true"
                checked={@form[:names_record].value in [true, "true"]}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Names the record (search finds it by this value)")}
            </label>
            <label class="flex items-center gap-2 self-end text-sm">
              <input type="hidden" name="field_definition[searchable]" value="false" />
              <input
                type="checkbox"
                name="field_definition[searchable]"
                value="true"
                checked={@form[:searchable].value in [true, "true"]}
                class="size-4 rounded border border-base-content/30 accent-primary"
              />
              {gettext("Searchable (search indexes this value as text)")}
            </label>
            <.relationship_summary
              form={@form}
              id="new-field-summary"
              source={scopes_label(@scopes, @content_types, @dynamic_types)}
              target_types={@target_types}
            />
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Add field")}</.button>
            </div>
          </.form>
        </section>

        <section class="space-y-6">
          <h2 class="text-lg font-medium">{gettext("Defined fields")}</h2>

          <.empty_state
            :if={@grouped == []}
            icon="hero-adjustments-horizontal"
            title={gettext("No custom fields yet")}
          >
            {gettext("Add a field above to collect structured metadata on content.")}
          </.empty_state>

          <p :if={@grouped != []} class="text-sm text-base-content/70">
            {gettext(
              "Fields appear in the editor in this order. Drag a field by its handle, or use the arrows, to move it."
            )}
          </p>

          <div :for={{scope, definitions} <- @grouped} class="space-y-3">
            <h3
              id={"fields-heading-#{group_dom_id(scope)}"}
              class="text-sm font-semibold text-base-content/80"
            >
              {group_heading(scope, @dynamic_types)}
            </h3>
            <ul
              id={"fields-#{group_dom_id(scope)}"}
              phx-hook="Sortable"
              aria-labelledby={"fields-heading-#{group_dom_id(scope)}"}
              class="card divide-y divide-base-content/10"
            >
              <li
                :for={{definition, index} <- Enum.with_index(definitions)}
                id={"field-#{definition.id}"}
                data-sort-id={definition.id}
                class="p-4"
              >
                <div
                  :if={!editing?(@edit, definition.id)}
                  class="flex items-start justify-between gap-4"
                >
                  <button
                    type="button"
                    data-drag-handle
                    aria-label={gettext("Drag to reorder %{label}", label: definition.label)}
                    title={gettext("Drag to reorder")}
                    class="-ml-1 cursor-grab rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content active:cursor-grabbing"
                  >
                    <.icon name="hero-bars-2" class="size-4" />
                  </button>
                  <div class="min-w-0 flex-1 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium">{definition.label}</span>
                      <code class="text-xs text-base-content/60">{definition.name}</code>
                      <span class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70">
                        {type_label(definition.field_type)}
                      </span>
                      <span
                        :if={definition.field_type == :media and definition.multiple}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("gallery")}
                      </span>
                      <span
                        :if={definition.field_type == :reference and definition.multiple}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("list")}
                      </span>
                      <span
                        :if={definition.field_type == :group and definition.multiple}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("repeating")}
                      </span>
                      <span
                        :if={definition.field_type == :string and definition.multiple}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("list")}
                      </span>
                      <span
                        :if={definition.field_type == :select and definition.multiple}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {if definition.allow_custom,
                          do: gettext("tags, open"),
                          else: gettext("several")}
                      </span>
                      <span
                        :if={definition.field_type == :text and definition.format == :plain}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("unformatted")}
                      </span>
                      <span
                        :if={definition.field_type == :text and definition.deliver_plain}
                        title={gettext("Also delivered as plain text (custom_fields_plain)")}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("plain")}
                      </span>
                      <span
                        :if={definition.private}
                        id={"field-#{definition.id}-private"}
                        title={gettext("Only editors and admins see the value")}
                        class="inline-flex items-center gap-1 rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        <.icon name="hero-lock-closed" class="size-3" />
                        {gettext("private")}
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
                    <p
                      :if={definition.field_type == :reference}
                      id={"field-#{definition.id}-links"}
                      class="text-xs text-base-content/60"
                    >
                      {reference_summary(definition, @target_types, @dynamic_types)}
                    </p>
                    <p
                      :if={
                        definition.field_type == :reference and
                          target_rules_summary(definition, @target_types) != ""
                      }
                      id={"field-#{definition.id}-rules"}
                      class="text-xs text-base-content/60"
                    >
                      {target_rules_summary(definition, @target_types)}
                    </p>
                    <p
                      :if={
                        definition.field_type == :reference and schema_org_summary(definition) != ""
                      }
                      id={"field-#{definition.id}-schema-org"}
                      class="text-xs text-base-content/60"
                    >
                      {schema_org_summary(definition)}
                    </p>
                    <p :if={definition.compute} class="text-xs text-base-content/60">
                      {gettext("Formula")}: <code>{definition.compute}</code>
                    </p>
                    <p
                      :if={definition.field_type == :group and definition.multiple}
                      id={"field-#{definition.id}-bounds"}
                      class="text-xs text-base-content/60"
                    >
                      {rows_summary(definition)}
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-1">
                    <button
                      type="button"
                      phx-click="move_field"
                      phx-value-id={definition.id}
                      phx-value-dir="up"
                      disabled={index == 0}
                      aria-label={gettext("Move %{label} up", label: definition.label)}
                      class="btn btn-sm btn-ghost px-1.5"
                    >
                      <.icon name="hero-chevron-up" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="move_field"
                      phx-value-id={definition.id}
                      phx-value-dir="down"
                      disabled={index == length(definitions) - 1}
                      aria-label={gettext("Move %{label} down", label: definition.label)}
                      class="btn btn-sm btn-ghost px-1.5"
                    >
                      <.icon name="hero-chevron-down" class="size-4" />
                    </button>
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
                <%!-- Under the field's row rather than inside its text column,
                      so the list keeps its width beside the buttons on a
                      phone; indented to the text on wider screens. --%>
                <div
                  :if={
                    !editing?(@edit, definition.id) and
                      definition.field_type in [:reference, :group]
                  }
                  class="sm:pl-10"
                >
                  <.link_fields_panel
                    definition={definition}
                    links={Map.get(@link_fields, definition.id, [])}
                    link_form={@link_form}
                    target_types={@target_types}
                  />
                </div>

                <.form
                  :if={editing?(@edit, definition.id)}
                  for={@edit.form}
                  id={"edit-field-#{definition.id}"}
                  phx-change="validate_edit"
                  phx-submit="save_edit"
                  class="grid gap-4 sm:grid-cols-2"
                >
                  <.kind_field form={@edit.form} id={"edit-field-kind-#{@edit.id}"} />
                  <%= if reference?(@edit.form) do %>
                    <input type="hidden" name={@edit.form[:field_type].name} value="reference" />
                    <.relationship_sides
                      form={@edit.form}
                      id={"edit-field-sides-#{@edit.id}"}
                      targets_id={"edit-field-targets-#{@edit.id}"}
                      target_types={@target_types}
                      source={group_heading(scope_key(definition), @dynamic_types)}
                    />
                    <.relationship_counts
                      form={@edit.form}
                      id={"edit-field-counts-#{@edit.id}"}
                      multiple_id={"edit-field-multiple-#{@edit.id}"}
                      target_types={@target_types}
                      source={group_heading(scope_key(definition), @dynamic_types)}
                    />
                    <.multiple_field
                      form={@edit.form}
                      id={"edit-field-multiple-#{@edit.id}"}
                      stored={definition}
                      target_types={@target_types}
                    />
                    <.relationship_names
                      form={@edit.form}
                      id={"edit-field-names-#{@edit.id}"}
                      inverse_id={"edit-field-inverse-#{@edit.id}"}
                      target_types={@target_types}
                      source={group_heading(scope_key(definition), @dynamic_types)}
                    />
                    <.relationship_rules
                      form={@edit.form}
                      id={"edit-field-rules-#{@edit.id}"}
                      target_types={@target_types}
                    />
                  <% else %>
                    <.input
                      field={@edit.form[:field_type]}
                      type="select"
                      label={gettext("Field type")}
                      options={value_type_options(@field_types)}
                      hint={type_description(@edit.form[:field_type].value, @field_types)}
                    />
                    <.input field={@edit.form[:label]} label={gettext("Label")} />
                    <.compute_builder
                      :if={computed?(@edit.form)}
                      form={@edit.form}
                      builder={@edit.builder}
                      ctx={@edit.ctx}
                      recipes={@recipes}
                      categories={@function_categories}
                      id={"edit-field-#{@edit.id}"}
                    />
                    <.multiple_field
                      form={@edit.form}
                      id={"edit-field-multiple-#{@edit.id}"}
                      stored={definition}
                      target_types={@target_types}
                    />
                  <% end %>
                  <.input field={@edit.form[:help_text]} label={gettext("Help text")} />
                  <.localization_input field={@edit.form[:localization]} />
                  <.options_field form={@edit.form} id={"edit-field-options-#{@edit.id}"} />
                  <.default_field form={@edit.form} />
                  <.text_format_field form={@edit.form} id={"edit-field-format-#{@edit.id}"} />
                  <.deliver_plain_field
                    form={@edit.form}
                    id={"edit-field-deliver-plain-#{@edit.id}"}
                  />
                  <.private_field form={@edit.form} id={"edit-field-private-#{@edit.id}"} />
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
                  <.relationship_summary
                    form={@edit.form}
                    id={"edit-field-summary-#{@edit.id}"}
                    source={group_heading(scope_key(definition), @dynamic_types)}
                    target_types={@target_types}
                  />
                  <div class="flex gap-2 sm:col-span-2">
                    <.button type="submit" variant="primary">{gettext("Save")}</.button>
                    <button
                      type="button"
                      phx-click="cancel_edit"
                      class="btn btn-sm btn-default"
                    >
                      {gettext("Cancel")}
                    </button>
                  </div>
                </.form>
              </li>
            </ul>
          </div>
        </section>

        <section
          :if={@orphaned != []}
          id="orphaned-fields"
          class="space-y-3"
          aria-labelledby="orphaned-fields-heading"
        >
          <div>
            <h2 id="orphaned-fields-heading" class="flex items-center gap-2 text-lg font-medium">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
              {gettext("Orphaned fields")}
            </h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "These fields belong to a content type that no longer exists — a removed plugin, or a type that was renamed or deleted. Nothing shows, checks or delivers them. Delete them to tidy up."
              )}
            </p>
          </div>
          <ul class="card divide-y divide-base-content/10 border-warning/40">
            <li :for={definition <- @orphaned} id={"field-#{definition.id}"} class="p-4">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0 space-y-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="font-medium">{definition.label}</span>
                    <code class="text-xs text-base-content/60">{definition.name}</code>
                    <span class="rounded bg-warning/20 px-1.5 py-0.5 text-xs text-warning">
                      {gettext("orphaned")}
                    </span>
                  </div>
                  <p class="text-xs text-base-content/60">
                    {gettext("Content type %{type} no longer exists.",
                      type: to_string(definition.content_type)
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={definition.id}
                  data-confirm={gettext("Delete this orphaned field?")}
                  aria-label={gettext("Delete orphaned field %{name}", name: definition.name)}
                  class="btn btn-sm btn-default shrink-0 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                  {gettext("Delete")}
                </button>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end

  attr :definition, :map, required: true
  attr :links, :list, required: true
  attr :link_form, :any, required: true
  attr :target_types, :list, required: true

  # A reference field's link fields (R3), worded for someone setting up a
  # relationship rather than a schema: "Details on each connection". A group's
  # sub-fields are the same list under the group, as "Fields in each row".
  defp link_fields_panel(assigns) do
    group? = assigns.definition.field_type == :group

    assigns =
      assigns
      |> assign(:group?, group?)
      |> assign(
        :root,
        if(group?,
          do: "field-#{assigns.definition.id}-sub-fields",
          else: "field-#{assigns.definition.id}-details"
        )
      )
      |> assign(
        :target,
        assigns.definition
        |> FieldDefinition.reference_targets()
        |> Enum.map(&type_label_for(assigns.target_types, &1))
        |> types_phrase()
      )
      |> assign(
        :open,
        assigns.link_form && assigns.link_form.parent == assigns.definition.id &&
          assigns.link_form
      )

    ~H"""
    <div
      id={@root}
      role="group"
      aria-labelledby={"#{@root}-heading"}
      class="mt-3 rounded-md border border-base-content/10 bg-base-200/30 p-3"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h4 id={"#{@root}-heading"} class="text-sm font-medium">
          {if @group?,
            do: gettext("Fields in each row"),
            else: gettext("Details on each connection")}
        </h4>
        <button
          :if={!(@open && is_nil(@open.id))}
          type="button"
          id={"#{@root}-add"}
          phx-click="link_new"
          phx-value-parent={@definition.id}
          class="inline-flex cursor-pointer items-center gap-1 rounded text-xs font-medium text-primary-ink transition-colors hover:underline"
        >
          <.icon name="hero-plus" class="size-3.5" />
          {if @group?, do: gettext("Add a field"), else: gettext("Add a detail")}
        </button>
      </div>
      <p :if={@group?} class="mt-0.5 text-xs text-base-content/60">
        {if @definition.multiple,
          do:
            gettext(
              "What an editor fills in on every row — an amount, a unit, a note. Plain values only: a row can't hold an image, a link to a record or another group."
            ),
          else:
            gettext(
              "The values this group holds together — a width, a height, a weight. Plain values only: a group can't hold an image, a link to a record or another group."
            )}
      </p>
      <p :if={!@group?} class="mt-0.5 text-xs text-base-content/60">
        {gettext(
          "What an editor fills in for every %{type} this field connects — a quantity, a role, a note. It belongs to the connection, not to either record.",
          type: @target || gettext("record")
        )}
      </p>

      <ol :if={@links != []} id={"#{@root}-list"} class="mt-2 divide-y divide-base-content/10">
        <li :for={{link, index} <- Enum.with_index(@links)} id={"link-field-#{link.id}"} class="py-2">
          <div :if={!(@open && @open.id == link.id)} class="flex items-center justify-between gap-3">
            <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm">
              <span class="font-medium">{link.label}</span>
              <code class="text-xs text-base-content/60">{link.name}</code>
              <span class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70">
                {type_label(link.field_type)}
              </span>
              <span
                :if={link.required}
                class="rounded bg-warning/20 px-1.5 py-0.5 text-xs text-warning"
              >
                {gettext("required")}
              </span>
              <span
                :if={link.field_type == :select and link.options != []}
                class="text-xs text-base-content/60"
              >
                {Enum.join(link.options, ", ")}
              </span>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <button
                type="button"
                phx-click="link_move"
                phx-value-id={link.id}
                phx-value-dir="up"
                disabled={index == 0}
                aria-label={gettext("Move %{label} up", label: link.label)}
                class="btn btn-sm btn-ghost px-1.5"
              >
                <.icon name="hero-chevron-up" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="link_move"
                phx-value-id={link.id}
                phx-value-dir="down"
                disabled={index == length(@links) - 1}
                aria-label={gettext("Move %{label} down", label: link.label)}
                class="btn btn-sm btn-ghost px-1.5"
              >
                <.icon name="hero-chevron-down" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="link_edit"
                phx-value-id={link.id}
                class="btn btn-sm btn-default"
              >
                {gettext("Edit")}
              </button>
              <button
                type="button"
                phx-click="delete"
                phx-value-id={link.id}
                data-confirm={
                  if @group?,
                    do: gettext("Delete this field? Its value is removed from every row."),
                    else: gettext("Delete this detail? Its value is removed from every connection.")
                }
                aria-label={
                  if @group?,
                    do: gettext("Delete field %{label}", label: link.label),
                    else: gettext("Delete detail %{label}", label: link.label)
                }
                class="rounded px-2 py-1 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
          <.link_field_form
            :if={@open && @open.id == link.id}
            form={@open.form}
            id={"link-field-form-#{link.id}"}
            group?={@group?}
          />
        </li>
      </ol>
      <p :if={@links == [] and !@open} class="mt-2 text-xs text-base-content/50">
        {if @group?,
          do: gettext("No fields yet — editors see nothing to fill in until you add one."),
          else: gettext("No details yet.")}
      </p>
      <.link_field_form
        :if={@open && is_nil(@open.id)}
        form={@open.form}
        id={"link-field-form-new-#{@definition.id}"}
        group?={@group?}
      />
    </div>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :group?, :boolean, default: false

  defp link_field_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-change="link_validate"
      phx-submit="link_save"
      class="mt-2 grid gap-3 rounded-md border border-base-content/10 bg-base-100 p-3 sm:grid-cols-2"
    >
      <.input
        field={@form[:label]}
        label={gettext("Label")}
        placeholder={if @group?, do: gettext("Unit"), else: gettext("Quantity")}
      />
      <.input
        field={@form[:name]}
        label={gettext("Machine name")}
        placeholder={if @group?, do: "unit", else: "quantity"}
        hint={gettext("Filled in from the label until you change it.")}
      />
      <.input
        field={@form[:field_type]}
        type="select"
        label={gettext("Kind of value")}
        options={link_type_options()}
      />
      <.input field={@form[:help_text]} label={gettext("Help text")} />
      <.options_field form={@form} id={"#{@id}-options"} />
      <.default_field form={@form} />
      <label class="flex items-center gap-2 self-end text-sm">
        <input type="hidden" name={@form[:required].name} value="false" />
        <input
          type="checkbox"
          name={@form[:required].name}
          value="true"
          checked={@form[:required].value in [true, "true"]}
          class="size-4 rounded border border-base-content/30 accent-primary"
        />
        {if @group?,
          do: gettext("Required on every row"),
          else: gettext("Required on every connection")}
      </label>
      <div class="flex gap-2 sm:col-span-2">
        <.button type="submit" variant="primary">
          {if @group?, do: gettext("Save field"), else: gettext("Save detail")}
        </.button>
        <button type="button" phx-click="link_cancel" class="btn btn-sm btn-default">
          {gettext("Cancel")}
        </button>
      </div>
    </.form>
    """
  end

  # Field-level localization (#1327): whether this field's value differs
  # between the locale variants of a document.
  attr :field, Phoenix.HTML.FormField, required: true

  defp localization_input(assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label={gettext("Across locales")}
      options={[
        {gettext("Translated per locale"), "localized"},
        {gettext("Shared: one value, set in the default locale"), "shared"},
        {gettext("Inherited when a translation leaves it empty"), "fallback"}
      ]}
      hint={
        gettext(
          "Shared values are copied to every translation when the default-locale version publishes."
        )
      }
    />
    """
  end
end
