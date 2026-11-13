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

  # The types `multiple_field/1` asks "one or a list" of (a reference asks it
  # in `relationship_counts/1`), the list-capable types by the name a form
  # posts — looked up, never `String.to_atom/1` — and the typed scalar lists
  # (#2289: numbers, dates, links, …).
  @holds_types [:media, :group] ++ KilnCMS.CMS.ScalarLists.types()
  @list_type_names Map.new(KilnCMS.CMS.Changes.ClearMultiple.list_types(), &{to_string(&1), &1})
  @typed_list_types KilnCMS.CMS.ScalarLists.typed()

  import KilnCMSWeb.ComputedBuilderComponents, only: [compute_builder: 1]
  import KilnCMSWeb.ConditionsBuilderComponents, only: [conditions_field: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.ClearMultiple
  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.DynamicDefaults
  alias KilnCMS.CMS.FieldConstraints
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldSection
  alias KilnCMS.CMS.FieldTypes
  alias KilnCMS.CMS.FieldWidgets
  alias KilnCMS.CMS.SectionLayouts
  alias KilnCMS.CMS.Validations.FieldCondition
  alias KilnCMSWeb.ComputedBuilder
  alias KilnCMSWeb.ConditionsBuilder

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

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
     |> assign(:cond_siblings, create_siblings(socket.assigns, default_scopes))
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
    {socket, conds} = apply_create_conditions(socket, params, scopes)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.validate(
        params
        |> normalize(List.first(scopes))
        |> put_rules(conds, params["field_type"], socket.assigns.cond_siblings)
      )
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
    {socket, conds} = apply_create_conditions(socket, params, scopes)
    assigns = socket.assigns
    socket = socket |> assign(:scopes, scopes) |> assign(:builder, builder)

    forms =
      Enum.map(scopes, fn scope ->
        # A new field goes to the end of its type's list (#1818); the list's
        # drag handles and arrows move it from there.
        params =
          params
          |> normalize(scope)
          |> put_rules(conds, params["field_type"], assigns.cond_siblings)
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
    case edit_form(id, socket.assigns.actor, socket.assigns.current_org) do
      {:ok, form} ->
        {:noreply,
         socket
         |> assign(:edit, %{
           id: id,
           form: form,
           builder: ComputedBuilder.new(form[:compute].value),
           ctx: nil,
           conds: edit_conds(socket.assigns, id),
           cond_siblings: edit_siblings(socket.assigns, id)
         })
         |> assign_edit_builder()}

      # Gone since the page loaded, or a field of an unknown type (#2605),
      # which no read but the list's returns: nothing to edit.
      :error ->
        {:noreply,
         socket
         |> load_definitions()
         |> put_flash(:error, gettext("That field can't be edited."))}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"field_definition" => params}, socket)
      when is_map(params) do
    params = params |> apply_kind() |> drop_default_on_type_change(socket.assigns.edit.form)
    {params, builder} = ComputedBuilder.apply_params(params, socket.assigns.edit.builder)
    old = socket.assigns.edit

    conds = ConditionsBuilder.apply_params(old.conds, params["conditions"], old.cond_siblings)

    edit = %{
      old
      | form:
          AshPhoenix.Form.validate(
            old.form,
            params
            |> normalize(nil, old.form.source.data)
            |> put_rules(conds, params["field_type"], old.cond_siblings)
          ),
        builder: builder,
        conds: conds
    }

    {:noreply, socket |> assign(:edit, edit) |> assign_edit_builder()}
  end

  def handle_event("save_edit", %{"field_definition" => params}, socket) when is_map(params) do
    {params, builder} =
      params |> apply_kind() |> ComputedBuilder.apply_params(socket.assigns.edit.builder)

    old = socket.assigns.edit

    conds = ConditionsBuilder.apply_params(old.conds, params["conditions"], old.cond_siblings)

    submitted =
      params
      |> normalize(nil, old.form.source.data)
      |> put_rules(conds, params["field_type"], old.cond_siblings)

    case AshPhoenix.Form.submit(old.form, params: submitted) do
      {:ok, definition} ->
        before = Enum.find(socket.assigns.definitions, &(&1.id == definition.id))

        {:noreply,
         socket
         |> carry_section_layout(before, definition)
         |> assign(:edit, nil)
         |> load_definitions()
         |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:edit, %{old | form: form, builder: builder, conds: conds})
         |> assign_edit_builder()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    # Unknown-type rows (#2605) included: deleting one is all this page
    # offers for it.
    socket =
      with {:ok, definition} <-
             CMS.get_field_definition(id,
               actor: actor,
               tenant: org,
               context: FieldDefinition.all_types_context()
             ),
           :ok <- refuse_if_read(definition, org),
           :ok <- CMS.destroy_field_definition(definition, actor: actor, tenant: org) do
        socket
        |> drop_section_layout(definition)
        |> load_definitions()
        |> put_flash(:info, gettext("Field deleted."))
      else
        {:read_by, labels} ->
          put_flash(
            socket,
            :error,
            gettext("%{fields} reads this field in a condition: remove that condition first.",
              fields: labels
            )
          )

        _ ->
          put_flash(socket, :error, gettext("Couldn't delete that field."))
      end

    {:noreply, assign(socket, :edit, nil)}
  end

  # --- conditions (#2277) ----------------------------------------------------

  # "Add a condition", the trash button, "Remove condition": the rows live in
  # the live view (the form posts them on every change), so these only edit
  # that state. Nothing is read or written here, but they are admin-only like
  # the rest of the page, so each re-checks.
  def handle_event("cond_add", %{"ctx" => ctx, "rule" => rule}, socket)
      when ctx in ["create", "edit", "link"] and rule in ["visible_when", "required_when"] do
    {:noreply,
     with_conds(socket, ctx, fn state, siblings ->
       ConditionsBuilder.add(state, rule, siblings)
     end)}
  end

  def handle_event("cond_remove", %{"ctx" => ctx, "rule" => rule, "index" => index}, socket)
      when ctx in ["create", "edit", "link"] and rule in ["visible_when", "required_when"] and
             is_binary(index) do
    case Integer.parse(index) do
      {index, ""} ->
        {:noreply,
         with_conds(socket, ctx, fn state, _siblings ->
           ConditionsBuilder.remove(state, rule, index)
         end)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("cond_clear", %{"ctx" => ctx, "rule" => rule}, socket)
      when ctx in ["create", "edit", "link"] and rule in ["visible_when", "required_when"] do
    {:noreply,
     with_conds(socket, ctx, fn state, _siblings -> ConditionsBuilder.clear(state, rule) end)}
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
           name_edited?: false,
           conds: ConditionsBuilder.new(),
           cond_siblings: link_siblings(socket.assigns, parent_id, nil, child_kind(type))
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
           name_edited?: true,
           conds: ConditionsBuilder.new(link),
           cond_siblings:
             link_siblings(
               socket.assigns,
               FieldDefinition.parent_id(link),
               id,
               if(link.group_of_id, do: :group, else: :link)
             )
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
    conds = ConditionsBuilder.apply_params(lf.conds, params["conditions"], lf.cond_siblings)

    form =
      AshPhoenix.Form.validate(
        lf.form,
        params |> link_params(lf) |> put_link_rules(lf, conds, params["field_type"])
      )

    {:noreply,
     assign(socket, :link_form, %{lf | form: form, name_edited?: name_edited?, conds: conds})}
  end

  def handle_event(
        "link_save",
        %{"link_field" => params},
        %{assigns: %{link_form: %{} = lf}} = socket
      )
      when is_map(params) do
    params = if lf.id == nil and blank?(params["name"]), do: suggest_name(params), else: params

    conds = ConditionsBuilder.apply_params(lf.conds, params["conditions"], lf.cond_siblings)

    submitted =
      params
      |> link_params(lf, socket.assigns)
      |> put_link_rules(lf, conds, params["field_type"])

    case AshPhoenix.Form.submit(lf.form, params: submitted) do
      {:ok, _link} ->
        {:noreply,
         socket
         |> assign(:link_form, nil)
         |> load_definitions()
         |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :link_form, %{lf | form: form, conds: conds})}
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

  # --- section layout (#2280) ------------------------------------------------

  # One row of a type's Sections panel, saved as its selects change. The type
  # and the section must be ones this page lists for this site: a stale page
  # or a hand-made event naming another site's type, or a section no field of
  # the type carries, writes nothing.
  def handle_event("section_layout", %{"scope" => scope, "name" => name} = params, socket)
      when is_binary(scope) and is_binary(name) do
    assigns = socket.assigns

    if CMS.can_create_field_section?(assigns.actor, %{}, tenant: assigns.current_org) do
      layout = if is_map(params["section"]), do: params["section"], else: %{}
      {:noreply, apply_section_layout(socket, scope, name, layout)}
    else
      {:noreply, put_flash(socket, :error, gettext("You can't change custom fields."))}
    end
  end

  # A forged scope, a section the type doesn't carry or a value outside the
  # closed sets writes nothing.
  defp apply_section_layout(socket, scope, name, layout) do
    assigns = socket.assigns

    with {owner, definitions} <-
           Enum.find(assigns.grouped, fn {owner, _} -> owner_param(owner) == scope end),
         true <- name in section_names(definitions),
         {:ok, display} <- layout_value(layout["display"], FieldSection.displays()),
         {:ok, initially} <- initially_value(layout["initially"], assigns, owner, name) do
      save_section_layout(socket, owner, name, display, initially)
    else
      _ -> socket
    end
  end

  # --- section layout helpers (#2280) ----------------------------------------

  # A section back at the default (an accordion opening by the panel's own
  # heuristic) keeps no row: no row renders exactly that, and the field
  # sync export then carries only the sections that differ. Every save also
  # prunes the type's rows that no field names any more. Both read the type's
  # rows and fields now, not from this page: another admin may have added a
  # section (and set its layout) since it loaded.
  defp save_section_layout(socket, owner, name, display, initially) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    result =
      with {:ok, rows} <- SectionLayouts.layouts(owner, opts),
           true <- written?(write_section_layout(rows, owner, name, display, initially, opts)) do
        SectionLayouts.prune(owner, opts)
      end

    socket = load_definitions(socket)

    if written?(result),
      do: socket,
      else: put_flash(socket, :error, gettext("Couldn't save the section layout."))
  end

  defp write_section_layout(rows, owner, name, display, initially, opts) do
    case {Enum.find(rows, &(&1.name == name)), display, initially} do
      {nil, :accordion, :auto} ->
        :ok

      {nil, display, initially} ->
        owner
        |> owner_attrs()
        |> Map.merge(%{name: name, display: display, initially: initially})
        |> CMS.create_field_section(opts)

      {row, :accordion, :auto} ->
        CMS.destroy_field_section(row, opts)

      {row, display, initially} ->
        CMS.update_field_section(row, %{display: display, initially: initially}, opts)
    end
  end

  # A field renamed out of a section it was the last field of takes the
  # section's layout to its new name, unless that name already has one: the
  # admin renamed the section, one field at a time.
  defp carry_section_layout(socket, %{section: old} = before, %{section: new})
       when is_binary(old) and is_binary(new) and old != new do
    owner = scope_key(before)
    rows = Map.get(socket.assigns.field_sections, owner, [])
    row = Enum.find(rows, &(&1.name == old))

    left_behind? =
      Enum.any?(
        socket.assigns.definitions,
        &(&1.id != before.id and scope_key(&1) == owner and &1.section == old)
      )

    if row && !left_behind? && !Enum.any?(rows, &(&1.name == new)) do
      opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

      carried =
        with {:ok, _} <-
               owner
               |> owner_attrs()
               |> Map.merge(%{name: new, display: row.display, initially: row.initially})
               |> CMS.create_field_section(opts) do
          CMS.destroy_field_section(row, opts)
        end

      if written?(carried),
        do: socket,
        else: put_flash(socket, :error, gettext("Couldn't save the section layout."))
    else
      socket
    end
  end

  defp carry_section_layout(socket, _before, _after), do: socket

  # The last field of a section takes the section's layout with it: nothing
  # is left for it to lay out, and the export would otherwise carry it.
  defp drop_section_layout(socket, %{section: section} = definition) when is_binary(section) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    with owner when not is_nil(owner) <- SectionLayouts.owner_of(definition),
         {:error, _error} <- SectionLayouts.prune(owner, [only: [section]] ++ opts) do
      put_flash(socket, :error, gettext("Couldn't save the section layout."))
    else
      _pruned -> socket
    end
  end

  defp drop_section_layout(socket, _definition), do: socket

  defp written?(:ok), do: true
  defp written?({:ok, _}), do: true
  defp written?(_error), do: false

  # The sections in use on one type, in the order the editor shows them:
  # each at the place of its first field.
  defp section_names(definitions) do
    definitions
    |> Enum.map(& &1.section)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp layout_value(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp layout_value(_value, _allowed), do: :error

  # The "Opens" select is disabled unless the section is an accordion, and a
  # disabled select posts nothing: the stored choice then stands, so it is
  # still there when the section is an accordion again.
  defp initially_value(nil, assigns, owner, name),
    do: {:ok, section_layout(assigns.field_sections, owner, name).initially}

  defp initially_value(value, _assigns, _owner, _name),
    do: layout_value(value, FieldSection.initial_states())

  # A section's stored layout, or the default a section without a row has.
  defp section_layout(field_sections, owner, name) do
    field_sections
    |> Map.get(owner, [])
    |> Enum.find(%{display: :accordion, initially: :auto}, &(&1.name == name))
  end

  defp owner_attrs({:compiled, type}), do: %{content_type: type}
  defp owner_attrs({:dynamic, id}), do: %{type_definition_id: id}

  defp owner_param({:compiled, type}), do: to_string(type)
  defp owner_param({:dynamic, id}), do: "def:#{id}"

  defp field_section_owner(%{type_definition_id: nil, content_type: type}), do: {:compiled, type}
  defp field_section_owner(%{type_definition_id: id}), do: {:dynamic, id}

  defp display_options do
    [
      {gettext("Accordion: a heading that opens and closes"), "accordion"},
      {gettext("Fieldset: always open, under its heading"), "fieldset"},
      {gettext("Tab: one tab of the type's tab set"), "tab"}
    ]
  end

  defp initially_options do
    [
      {gettext("Automatically (open when it holds a value)"), "auto"},
      {gettext("Open (expanded)"), "expanded"},
      {gettext("Closed (collapsed)"), "collapsed"}
    ]
  end

  # --- conditions helpers (#2277) ---------------------------------------------

  defp with_conds(socket, ctx, fun) do
    assigns = socket.assigns

    if CMS.can_create_field_definition?(assigns.actor, %{}, tenant: assigns.current_org) do
      case conds_for(assigns, ctx) do
        {state, siblings} -> put_conds(socket, ctx, fun.(state, siblings))
        nil -> socket
      end
    else
      put_flash(socket, :error, gettext("You can't change custom fields."))
    end
  end

  defp conds_for(assigns, "create"), do: {assigns.conds, assigns.cond_siblings}
  defp conds_for(%{edit: %{} = edit}, "edit"), do: {edit.conds, edit.cond_siblings}
  defp conds_for(%{link_form: %{} = lf}, "link"), do: {lf.conds, lf.cond_siblings}
  defp conds_for(_assigns, _ctx), do: nil

  defp put_conds(socket, "create", state), do: assign(socket, :conds, state)

  defp put_conds(%{assigns: %{edit: %{} = edit}} = socket, "edit", state),
    do: assign(socket, :edit, %{edit | conds: state})

  defp put_conds(%{assigns: %{link_form: %{} = lf}} = socket, "link", state),
    do: assign(socket, :link_form, %{lf | conds: state})

  defp put_conds(socket, _ctx, _state), do: socket

  # The create form's rows follow the ticked types: the fields a rule may read
  # are the ones every ticked type has by that name and type.
  defp apply_create_conditions(socket, params, scopes) do
    socket =
      if scopes == socket.assigns.scopes and Map.has_key?(socket.assigns, :cond_siblings),
        do: socket,
        else: assign(socket, :cond_siblings, create_siblings(socket.assigns, scopes))

    conds =
      ConditionsBuilder.apply_params(
        socket.assigns.conds,
        params["conditions"],
        socket.assigns.cond_siblings
      )

    {assign(socket, :conds, conds), conds}
  end

  defp create_siblings(_assigns, []), do: []

  defp create_siblings(assigns, scopes) do
    [first | rest] = Enum.map(scopes, &scope_siblings(&1, assigns.current_org))

    Enum.filter(first, fn s ->
      Enum.all?(rest, fn other ->
        Enum.any?(other, &(&1.name == s.name and &1.field_type == s.field_type))
      end)
    end)
  end

  defp scope_siblings("def:" <> id, org),
    do: cond_siblings(%{id: nil, type_definition_id: id}, org, nil)

  defp scope_siblings(type, org),
    do: cond_siblings(%{id: nil, content_type: String.to_existing_atom(type)}, org, nil)

  defp edit_siblings(assigns, id) do
    case Enum.find(assigns.definitions, &(&1.id == id)) do
      nil -> []
      definition -> cond_siblings(definition, assigns.current_org, definition.name)
    end
  end

  # A group's sub-fields read each other; a reference's link fields carry no
  # conditions.
  defp link_siblings(assigns, parent_id, id, :group),
    do: cond_siblings(%{id: id, group_of_id: parent_id}, assigns.current_org, nil)

  defp link_siblings(_assigns, _parent_id, _id, _kind), do: []

  defp cond_siblings(scope, org, own_name) do
    scope =
      Map.merge(
        %{
          id: nil,
          content_type: nil,
          type_definition_id: nil,
          group_of_id: nil,
          link_of_id: nil
        },
        Map.take(scope, [:id, :content_type, :type_definition_id, :group_of_id, :link_of_id])
      )

    scope
    |> FieldCondition.siblings(org)
    |> Enum.filter(&(&1.field_type in FieldDefinition.link_field_types() and not &1.private))
    |> Enum.reject(&(&1.name == own_name))
    |> Enum.sort_by(& &1.position)
  end

  # The rules for the params the resource validates. A type that carries none
  # (a group or computed field) sends both as nil so a stale row can't fail it.
  defp put_rules(params, _conds, type, _siblings) when type in ["group", "computed"],
    do: Map.merge(params, %{"visible_when" => nil, "required_when" => nil})

  defp put_rules(params, conds, _type, siblings),
    do: Map.merge(params, ConditionsBuilder.rule_params(conds, siblings))

  defp put_link_rules(params, %{kind: :group, cond_siblings: siblings}, conds, type),
    do: put_rules(params, conds, type, siblings)

  defp put_link_rules(params, _lf, _conds, _type), do: params

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
    |> assign(:conds, ConditionsBuilder.new())
    |> assign(
      :cond_siblings,
      create_siblings(socket.assigns, socket.assigns.default_scopes)
    )
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
    params = params |> normalize() |> without_unique() |> Map.put(column, parent_id)

    case assigns do
      nil -> params
      assigns -> Map.put(params, "position", length(Map.get(assigns.link_fields, parent_id, [])))
    end
  end

  defp link_params(params, _link_form, _assigns),
    do: params |> normalize() |> without_unique() |> Map.drop(["link_of_id", "group_of_id"])

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

    # A field of an unknown type (#2605) still holds its name on its type.
    taken_on =
      (assigns.definitions ++ assigns.unknown_type)
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

  # The edit form's condition rows. A rule naming a sibling of an unknown
  # type (#2605) can't be shown as rows (the field picker offers no such
  # field, and re-posting would rewrite it), so it is kept as stored.
  defp edit_conds(assigns, id) do
    definition = Enum.find(assigns.definitions, &(&1.id == id))

    held =
      for unknown <- assigns.unknown_type,
          definition,
          is_nil(FieldDefinition.parent_id(unknown)),
          scope_key(unknown) == scope_key(definition),
          do: unknown.name

    definition |> ConditionsBuilder.new() |> ConditionsBuilder.hold(held)
  end

  # The resource refuses to delete a field another field's condition reads
  # (`Validations.FieldCondition`); asked first, so the flash can say which.
  defp refuse_if_read(definition, org) do
    case FieldCondition.dependents(definition, org) do
      [] -> :ok
      dependents -> {:read_by, Enum.map_join(dependents, ", ", & &1.label)}
    end
  end

  defp load_definitions(socket) do
    {links, definitions} =
      CMS.list_field_definitions!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [position: :asc, name: :asc]],
        context: FieldDefinition.all_types_context()
      )
      # Link fields (R3) are listed under their reference field, and a
      # group's sub-fields under their group — not as fields of a type.
      |> Enum.split_with(&(not is_nil(FieldDefinition.parent_id(&1))))

    # A link field or sub-field of an unknown type (#2605) is listed with the
    # other unknown-type fields, under its parent's name: its parent's editor
    # offers only the plain types.
    {unknown_links, links} = Enum.split_with(links, &FieldDefinition.unknown_type?/1)

    # A definition whose content type no longer exists (#1770) is listed on
    # its own, with only a delete: nothing renders, validates or delivers it,
    # and it cannot be saved back while it points at nothing.
    {orphaned, definitions} = Enum.split_with(definitions, &FieldDefinition.orphaned?/1)

    # So is one whose field type this release does not know (#2605): the
    # editor and delivery skip it, its values are kept, and it cannot be
    # edited or reordered — only deleted.
    {unknown_type, owned} = Enum.split_with(definitions, &FieldDefinition.unknown_type?/1)
    definitions = orphaned ++ owned

    grouped =
      owned
      |> Enum.group_by(&scope_key/1)
      |> Enum.sort_by(fn {scope, _definitions} ->
        group_heading(scope, socket.assigns.dynamic_types)
      end)

    socket
    |> assign(:definitions, definitions)
    # Every section heading in use on the site, offered as the section
    # input's suggestions so a second field files under the same spelling.
    |> assign(
      :section_names,
      definitions
      |> Enum.map(& &1.section)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
    )
    |> assign(:link_fields, Enum.group_by(links, &FieldDefinition.parent_id/1))
    |> assign(:grouped, grouped)
    # Each type's section layouts (#2280), by owner, for its Sections panel.
    |> assign(
      :field_sections,
      CMS.list_field_sections!(actor: socket.assigns.actor, tenant: socket.assigns.current_org)
      |> Enum.group_by(&field_section_owner/1)
    )
    |> assign(:orphaned, Enum.sort_by(orphaned, &{to_string(&1.content_type), &1.name}))
    |> assign(:unknown_type, unknown_type ++ unknown_links)
  end

  # Where a field of an unknown type (#2605) sits: its type, or for a link
  # field or sub-field, its parent field.
  defp unknown_owner(definition, definitions, dynamic_types) do
    case FieldDefinition.parent_id(definition) do
      nil ->
        group_heading(scope_key(definition), dynamic_types)

      parent_id ->
        case Enum.find(definitions, &(&1.id == parent_id)) do
          %{label: label} -> label
          nil -> gettext("a field that is gone")
        end
    end
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
    case CMS.get_field_definition(id, actor: actor, tenant: org) do
      {:ok, definition} -> {:ok, update_form(definition, id, actor, org)}
      {:error, _not_found} -> :error
    end
  end

  defp update_form(definition, id, actor, org) do
    definition
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
  # The editor input (#2284) is held to what the posted settings offer, read
  # over `record` — the stored definition being edited, nil for a new one.
  defp normalize(params, scope \\ nil, record \\ nil) do
    type = params["field_type"]
    pairs = if type in [nil, "select"], do: parse_option_pairs(params["options"]), else: []
    options = Enum.map(pairs, &elem(&1, 0))
    labels = for {value, label} <- pairs, label != nil, into: %{}, do: {value, label}

    default =
      cond do
        is_nil(type) -> params["default"]
        type not in @default_types -> nil
        type == "select" and params["default"] not in options -> nil
        true -> params["default"]
      end

    params
    |> Map.delete("scopes")
    |> Map.delete("conditions")
    |> Map.put("options", options)
    |> Map.put("option_labels", labels)
    |> Map.put("default", default)
    |> blank_source()
    |> unpack_validation()
    |> unpack_targets()
    |> unpack_sources_limit()
    |> unpack_inverse()
    |> unpack_widget(record)
    |> unpack_scope(scope)
  end

  # The widget cards (#2284) are only those the posted settings offer, and
  # change with them: a card checked before a retype, a `multiple` flip or a
  # switch to rich text leaves the page, so a widget the field no longer
  # offers is dropped here rather than refused on save. Worked out as the
  # save's `Validations.FieldWidget` will: the posted settings over the
  # stored ones. The default's card posts `""`, which is no widget stored.
  defp unpack_widget(%{"widget" => widget} = params, record) do
    widget = if widget in [nil, ""], do: nil, else: widget
    offered = params |> widget_subject(record) |> FieldWidgets.allowed()

    Map.put(params, "widget", if(widget in offered, do: widget))
  end

  defp unpack_widget(params, _record), do: params

  # The definition the widget allow-list is asked about: the posted settings
  # it reads (options already split) over the stored definition, or a new
  # one's. A setting the form didn't post keeps its stored value, as the
  # save's changeset does.
  defp widget_subject(params, record) do
    base = record || %FieldDefinition{}

    struct(base,
      field_type: posted_type(params["field_type"], base.field_type),
      multiple: posted_bool(params, "multiple", base.multiple),
      allow_custom: posted_bool(params, "allow_custom", base.allow_custom),
      format: posted_format(params["format"], base.format),
      options: if(is_list(params["options"]), do: params["options"], else: base.options),
      widget: posted_widget(params, base.widget)
    )
  end

  # A registered type's atom for a posted name; never a new atom.
  defp posted_type(type, fallback) when is_binary(type),
    do: Enum.find(FieldTypes.names(), fallback, &(Atom.to_string(&1) == type))

  defp posted_type(type, _fallback) when is_atom(type) and not is_nil(type), do: type
  defp posted_type(_type, fallback), do: fallback

  defp posted_bool(params, key, fallback) do
    case params[key] do
      value when value in [true, "true"] -> true
      value when value in [false, "false"] -> false
      _absent -> fallback
    end
  end

  defp posted_format(format, _fallback) when format in ["plain", :plain], do: :plain
  defp posted_format(format, _fallback) when format in ["rich", :rich], do: :rich
  defp posted_format(_format, fallback), do: fallback

  defp posted_widget(params, fallback) do
    case Map.fetch(params, "widget") do
      {:ok, widget} when widget in [nil, ""] -> nil
      {:ok, widget} -> widget
      :error -> fallback
    end
  end

  # The widget subject for a rendered form: what it last validated over the
  # definition it edits.
  defp form_widget_subject(%Phoenix.HTML.Form{source: %AshPhoenix.Form{} = source}),
    do: widget_subject(source.params || %{}, source.data)

  # The Validation fieldset posts every constraint as text (#2276). Blank
  # ones are dropped, numbers parsed, and the keys that mean nothing for the
  # chosen type left out — its inputs leave the page on a type change, and
  # `Validations.FieldConstraints` refuses what is stale. A value that is no
  # number stays text, so the save names the input it is wrong in. Without a
  # type in the params the constraints are left as they were.
  defp unpack_validation(%{"field_type" => type} = params) when is_binary(type) do
    allowed = FieldConstraints.allowed_keys(type_atom(type), format_atom(params["format"]))

    allowed =
      if params["multiple"] in [true, "true"], do: allowed -- ["unique"], else: allowed

    posted = if is_map(params["validation"]), do: params["validation"], else: %{}

    validation =
      for key <- allowed,
          {:ok, value} <- [constraint_value(key, type, posted[key])],
          into: %{},
          do: {key, value}

    validation =
      if Map.has_key?(validation, "pattern"),
        do: validation,
        else: Map.delete(validation, "pattern_message")

    Map.put(params, "validation", validation)
  end

  defp unpack_validation(params), do: params

  defp constraint_value("unique", _type, value),
    do: if(value in [true, "true"], do: {:ok, true}, else: :error)

  defp constraint_value(key, type, value) when key in ["min", "max"] and is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> :error
      type == "integer" -> {:ok, number(Integer.parse(value), value)}
      true -> {:ok, number(Float.parse(value), value)}
    end
  end

  defp constraint_value(key, _type, value)
       when key in ["min_length", "max_length"] and is_binary(value) do
    value = String.trim(value)
    if value == "", do: :error, else: {:ok, number(Integer.parse(value), value)}
  end

  defp constraint_value(key, _type, value) when key in ["pattern", "pattern_message"] do
    if is_binary(value) and String.trim(value) != "", do: {:ok, value}, else: :error
  end

  defp constraint_value(_key, _type, value) when is_number(value), do: {:ok, value}
  defp constraint_value(_key, _type, _value), do: :error

  defp number({number, ""}, _text), do: number
  defp number(_unparsed, text), do: text

  defp type_atom("integer"), do: :integer
  defp type_atom("float"), do: :float
  defp type_atom("string"), do: :string
  defp type_atom("url"), do: :url
  defp type_atom("text"), do: :text
  defp type_atom("date"), do: :date
  defp type_atom("datetime"), do: :datetime
  defp type_atom(_other), do: :other

  defp format_atom("plain"), do: :plain
  defp format_atom(_other), do: :rich

  # A detail on a connection or a field in a group is never unique.
  defp without_unique(%{"validation" => %{} = validation} = params),
    do: Map.put(params, "validation", Map.delete(validation, "unique"))

  defp without_unique(params), do: params

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

  # The options textarea: one option per line, or several on a line split by
  # commas, as before labels existed. A line holding `value | Label` is one
  # option with a label (`option_labels`) — the label may hold commas, which
  # is why such a line is never split.
  defp parse_option_pairs(options) when is_binary(options) do
    options
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, "|", parts: 2) do
        [value, label] -> [{String.trim(value), blank_to_nil(String.trim(label))}]
        [line] -> line |> String.split(",") |> Enum.map(&{String.trim(&1), nil})
      end
    end)
    |> Enum.reject(&(elem(&1, 0) == ""))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp parse_option_pairs(_options), do: []

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # Whether the options textarea applies: a `:select` field is the only type
  # that reads `options` (#1819).
  defp select?(form), do: to_string(form[:field_type].value) == "select"

  # Whether the default-value input applies (#1820).
  defp default?(form), do: to_string(form[:field_type].value) in @default_types

  # Whether the reference-target select applies to the form's current type.
  defp reference?(form), do: to_string(form[:field_type].value) == "reference"

  # Whether the Conditions disclosure applies: not to a group as a whole or a
  # computed field (`Validations.FieldCondition`).
  defp conditions?(form), do: to_string(form[:field_type].value) not in ["group", "computed"]

  # Whether the compute-formula textarea applies (a `:computed` field, #429).
  defp computed?(form), do: to_string(form[:field_type].value) == "computed"

  defp unpack_scope(params, nil), do: params

  defp unpack_scope(params, "def:" <> id),
    do: params |> Map.put("type_definition_id", id) |> Map.put("content_type", nil)

  defp unpack_scope(params, type),
    do: params |> Map.put("content_type", type) |> Map.put("type_definition_id", nil)

  # Textarea value for the options field: the stored list joined by newlines.
  # The textarea's text for the stored options: `value | Label` for an option
  # with a label, the bare value otherwise.
  defp options_text(form) do
    labels =
      case form[:option_labels].value do
        %{} = labels -> labels
        _none -> %{}
      end

    case form[:options].value do
      list when is_list(list) -> Enum.map_join(list, "\n", &option_line(&1, labels))
      str when is_binary(str) -> str
      _ -> ""
    end
  end

  defp option_line(value, labels) do
    case Map.get(labels, value) do
      nil -> value
      label -> "#{value} | #{label}"
    end
  end

  # `{label, value}` pairs for the default-value select.
  defp option_choices(form) do
    for {value, label} <- form |> options_text() |> parse_option_pairs(),
        do: {label || value, value}
  end

  # The options as an admin reads them in the list: the label, with the stored
  # value beside it when they differ.
  defp options_summary(definition) do
    Enum.map_join(definition.options, ", ", fn value ->
      case FieldDefinition.option_label(definition, value) do
        ^value -> value
        label -> "#{label} (#{value})"
      end
    end)
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
  # The labels of the computed fields whose formula reads this one: a formula
  # skips a list, so making the field a list is worth a warning (#2289).
  attr :formula_readers, :list, default: []

  # Single image or a gallery, for a `:media` field — or one row or repeating
  # rows, for a `:group`, or one line or a list, for a `:string`, or one term
  # or several, for a `:select` (which then
  # also asks whether editors may add terms of their own, `allow_custom`), or
  # one value or a list, for a typed scalar (a number, a date, a link, #2289) —
  # with the list's optional item bounds. A `:reference` field asks the same question from
  # both sides in `relationship_counts/1`; this keeps only the warning, shown
  # whenever a stored list is about to become a single item or another type.
  defp multiple_field(assigns) do
    type = list_type(assigns.form)
    multiple? = assigns.form[:multiple].value in [true, "true"]
    stored_type = list_type(assigns.stored)
    target = target_label(assigns.form, assigns.target_types)

    holds? = type in @holds_types

    {narrowing, retyped_list} = list_change(stored_type, type, holds?, multiple?)

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:holds?, holds?)
      |> assign(:multiple?, multiple?)
      |> assign(:target, target)
      |> assign(:choices, multiple_choices(type, target))
      # Checkboxes draw only the options (#2284): while they are the chosen
      # input, the open vocabulary is off and says why.
      |> assign(
        :checkboxes?,
        type == :select and multiple? and
          FieldWidgets.resolve(form_widget_subject(assigns.form)) == "checkboxes"
      )
      |> assign(:narrowing, narrowing)
      |> assign(:retyped_list, retyped_list)
      |> assign(
        :formula_warning?,
        holds? and multiple? and is_nil(stored_type) and assigns.formula_readers != []
      )

    # The warning outlives the toggle: retyping a list field to another type
    # narrows it just the same (`SyncFieldValues`), so it shows then too.
    ~H"""
    <div :if={@holds? || @narrowing || @retyped_list} class="sm:col-span-2">
      <fieldset :if={@holds?}>
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
            <span class="font-normal text-base-content/70">{gettext("(optional)")}</span>
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
            checked={@form[:allow_custom].value in [true, "true"] and not @checkboxes?}
            disabled={@checkboxes?}
            aria-describedby={if @checkboxes?, do: "#{@id}-allow-custom-conflict"}
            class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary disabled:cursor-not-allowed disabled:opacity-60"
          />
          <span>
            {gettext("Editors can add new terms")}
            <span class="block text-xs text-base-content/70">
              {gettext(
                "For a vocabulary that grows, like properties or keywords. The options become suggestions, and terms already used on this type are suggested too. A new term does not join the options."
              )}
            </span>
            <span
              :if={@checkboxes?}
              id={"#{@id}-allow-custom-conflict"}
              class="mt-0.5 block text-xs text-base-content/70"
            >
              {gettext(
                "Checkboxes show only the options. Pick Tags as the editor input to allow new terms."
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
      <p
        :if={@retyped_list}
        id={"#{@id}-retyped"}
        role="status"
        class="mt-2 flex items-start gap-1.5 text-xs text-warning-ink"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
        {gettext(
          "Lists already filled in keep their items as they are, not converted to the new type. An item the new type cannot hold is reported when that content is next saved; copy them into a new list field with mix kiln.fields.convert."
        )}
      </p>
      <p
        :if={@formula_warning?}
        id={"#{@id}-formulas"}
        role="status"
        class="mt-2 flex items-start gap-1.5 text-xs text-warning-ink"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
        {gettext(
          "Read by a formula in %{fields}. A formula skips a list: sum, min, max and text leave this field out once it holds one.",
          fields: Enum.join(@formula_readers, ", ")
        )}
      </p>
    </div>
    """
  end

  # A list of phrases or a typed list (#2289) — what the field list badges
  # "list"; a multiple select is badged by its own words.
  defp scalar_list?(type), do: type == :string or type in @typed_list_types

  # The labels of the computed fields among `definitions` whose formula reads
  # `definition` (`Computed.references/1`).
  defp formula_readers(definitions, definition) do
    for %{field_type: :computed} = reader <- definitions,
        reader.id != definition.id,
        definition.name in Computed.references(reader.compute),
        do: reader.label
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

  # A field's value constraints in the list (#2276), when it has any.
  defp constraints_summary(%{validation: validation}) do
    validation = FieldConstraints.normalize(validation)

    [
      range_summary(validation["min"], validation["max"]),
      length_summary(validation["min_length"], validation["max_length"]),
      if(validation["pattern"], do: gettext("Must match a pattern.")),
      if(validation["unique"] == true, do: gettext("Each value used once."))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp range_summary(nil, nil), do: nil
  defp range_summary(min, nil), do: gettext("At least %{min}.", min: min)
  defp range_summary(nil, max), do: gettext("At most %{max}.", max: max)
  defp range_summary(min, max), do: gettext("From %{min} to %{max}.", min: min, max: max)

  defp length_summary(nil, nil), do: nil

  defp length_summary(min, nil),
    do: ngettext("At least %{count} character.", "At least %{count} characters.", min)

  defp length_summary(nil, max),
    do: ngettext("At most %{count} character.", "At most %{count} characters.", max)

  defp length_summary(min, max),
    do: gettext("%{min} to %{max} characters.", min: min, max: max)

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

  # What becomes of a stored list (`stored_type`, nil when the stored field
  # holds no list) as the form now stands: `{narrowing, retyped_list}`.
  # Retyping a list into another type that is still a list leaves the saved
  # items as they are (`SyncFieldValues`); anything else narrows them.
  defp list_change(nil, _type, _holds?, _multiple?), do: {nil, nil}
  defp list_change(stored, type, true, true) when type != stored, do: {nil, stored}
  defp list_change(stored, type, _holds?, _multiple?) when type != stored, do: {stored, nil}
  defp list_change(stored, _type, _holds?, false), do: {stored, nil}
  defp list_change(_stored, _type, _holds?, true), do: {nil, nil}

  # The list-capable type a form or a stored definition is, or nil.
  defp list_type(nil), do: nil

  defp list_type(%Phoenix.HTML.Form{} = form),
    do: Map.get(@list_type_names, to_string(form[:field_type].value))

  defp list_type(%{field_type: type, multiple: true}) do
    if type in ClearMultiple.list_types(), do: type
  end

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

  defp multiple_choices(type, _target) when type in @typed_list_types do
    [
      {"false", gettext("One value"), gettext("A single value."), "hero-minus"},
      {"true", gettext("A list"),
       gettext(
         "As many values as the editor adds, each checked as a single one would be, in their order — dates, links, numbers."
       ), "hero-list-bullet"}
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

  defp narrowing_warning(type) when type == :string or type in @typed_list_types,
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

  attr :field, Phoenix.HTML.FormField, required: true
  attr :names, :list, required: true

  # The heading the field is filed under in the content editor (`section`),
  # with the site's headings in use as suggestions.
  defp section_input(assigns) do
    assigns = assign(assigns, :list_id, "#{assigns.field.id}-sections")

    ~H"""
    <div>
      <.input
        field={@field}
        label={gettext("Section")}
        list={@list_id}
        autocomplete="off"
        placeholder={gettext("e.g. Identity, Safety")}
        hint={gettext("Editors see fields with the same section under one collapsible heading.")}
      />
      <datalist id={@list_id}>
        <option :for={name <- @names} value={name} />
      </datalist>
    </div>
    """
  end

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

  # Which editor input the field uses (`widget`, #2284): a card per input its
  # settings offer (`FieldWidgets.allowed/1`), the type's default first and
  # posting `""`. Shown only when there is a choice, so it follows the type,
  # `multiple` and `format` above it. Checkboxes stay listed, disabled, while
  # editors may add terms of their own; a card drawing one input per option
  # says when the field lists too many for it. A line under the legend says
  # the choice is editor-only (#2674). Public for its test: the page itself
  # drops a widget the posted settings don't offer (`unpack_widget/2`), so
  # the state with an error and no cards has no ordinary path through it.
  @doc false
  def widget_field(assigns) do
    subject = form_widget_subject(assigns.form)
    allowed = FieldWidgets.allowed(subject)
    # The cards a choice of `allow_custom` would offer: checkboxes stay on
    # view, disabled, so the conflict is named rather than hidden.
    listed = FieldWidgets.allowed(%{subject | allow_custom: false})
    default = List.first(listed)

    assigns =
      assigns
      |> assign(:selected, FieldWidgets.resolve(subject) || default)
      |> assign(:default, default)
      # A refused widget (a plugin's list changed between render and save)
      # must say why, even when the field no longer offers a choice at all.
      |> assign(:errors, Enum.map(assigns.form[:widget].errors, &translate_error/1))
      |> assign(:cap_hint, if(FieldWidgets.too_many_options?(subject), do: cap_hint(subject)))
      |> assign(
        :choices,
        for name <- listed do
          {title, hint, icon} = widget_choice(subject, name)
          {name, title, hint, icon, name not in allowed}
        end
      )

    ~H"""
    <fieldset
      :if={length(@choices) > 1 or @errors != []}
      id={@id}
      class="sm:col-span-2"
      aria-describedby={if length(@choices) > 1, do: "#{@id}-help"}
    >
      <legend class="mb-1 block text-sm font-medium">{gettext("Editor input")}</legend>
      <p :if={length(@choices) > 1} id={"#{@id}-help"} class="mb-2 text-xs text-base-content/60">
        {gettext("How editors fill this in. What they enter is stored and delivered the same way.")}
      </p>
      <div :if={length(@choices) > 1} class="grid gap-2 sm:grid-cols-3">
        <label
          :for={{name, title, hint, icon, disabled?} <- @choices}
          for={"#{@id}-#{name}"}
          class={[
            "flex items-start gap-3 rounded-lg border p-3 transition-colors",
            cond do
              disabled? -> "cursor-not-allowed border-base-content/10 opacity-70"
              @selected == name -> "cursor-pointer border-primary bg-primary/5"
              true -> "cursor-pointer border-base-content/15 hover:border-base-content/30"
            end
          ]}
        >
          <input
            type="radio"
            id={"#{@id}-#{name}"}
            name={@form[:widget].name}
            value={if name == @default, do: "", else: name}
            checked={@selected == name and not disabled?}
            disabled={disabled?}
            class="mt-0.5 size-4 accent-primary"
          />
          <span class="min-w-0">
            <span class="flex items-center gap-1.5 text-sm font-medium">
              <.icon name={icon} class="size-4 text-base-content/70" />
              {title}
            </span>
            <span :if={hint} class="mt-0.5 block text-xs text-base-content/70">{hint}</span>
            <span
              :if={disabled?}
              id={"#{@id}-#{name}-conflict"}
              class="mt-0.5 block text-xs text-base-content/70"
            >
              {gettext("Not while editors can add new terms.")}
            </span>
            <span
              :if={@cap_hint && FieldWidgets.per_option?(name) && not disabled?}
              id={"#{@id}-#{name}-cap"}
              class="mt-0.5 flex items-start gap-1 text-xs text-warning-ink"
            >
              <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
              {@cap_hint}
            </span>
          </span>
        </label>
      </div>
      <p :for={error <- @errors} class="mt-1 flex items-center gap-1.5 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />{error}
      </p>
    </fieldset>
    """
  end

  # What a radios, buttons or checkboxes card says on a field listing more
  # options than the editor draws one input each for (`FieldWidgets.effective/1`).
  defp cap_hint(%{multiple: true}),
    do:
      gettext("Over %{count} options — the editor shows tags instead.",
        count: FieldWidgets.option_cap()
      )

  defp cap_hint(_subject),
    do:
      gettext("Over %{count} options — the editor shows a dropdown instead.",
        count: FieldWidgets.option_cap()
      )

  # The card for one widget: its title, a line on when to pick it, an icon.
  # Core widgets are named here (translated); a plugin's by its own label,
  # or its machine name humanized.
  defp widget_choice(%{field_type: :select, multiple: true}, "tags"),
    do: {gettext("Tags"), gettext("Picked terms as chips, with a search box."), "hero-tag"}

  defp widget_choice(%{field_type: :select, multiple: true}, "checkboxes"),
    do:
      {gettext("Checkboxes"), gettext("A box to tick beside every option."), "hero-check-circle"}

  defp widget_choice(%{field_type: :select}, "dropdown"),
    do:
      {gettext("Dropdown"),
       gettext("A menu that opens on click — compact for any number of options."),
       "hero-chevron-up-down"}

  defp widget_choice(%{field_type: :select}, "radios"),
    do:
      {gettext("Radio buttons"), gettext("Every option on view, one per line."),
       "hero-list-bullet"}

  defp widget_choice(%{field_type: :select}, "buttons"),
    do:
      {gettext("Buttons"),
       gettext("Every option on view as a row of buttons — for a few short ones."),
       "hero-squares-2x2"}

  defp widget_choice(%{field_type: :text}, "textarea"),
    do:
      {gettext("Several lines"), gettext("A box that grows with the text."),
       "hero-bars-3-bottom-left"}

  defp widget_choice(%{field_type: :text}, "single_line"),
    do:
      {gettext("One line"),
       gettext("A single-line box. Text that already has line breaks still opens on several."),
       "hero-minus"}

  defp widget_choice(%{field_type: :reference}, "autocomplete"),
    do:
      {gettext("Search as you type"), gettext("A search box that finds the record by its title."),
       "hero-magnifying-glass"}

  defp widget_choice(%{field_type: :reference}, "dropdown"),
    do:
      {gettext("Dropdown list"),
       gettext(
         "Every record to link to in one list — for a short one. Past 100, the editor searches instead."
       ), "hero-chevron-up-down"}

  defp widget_choice(subject, name) do
    label = Map.get(FieldWidgets.plugin_labels(subject), name) || Phoenix.Naming.humanize(name)
    {label, nil, "hero-puzzle-piece"}
  end

  # The label of the widget a stored definition uses, for its row in the list
  # of fields — only when it isn't the type's default.
  defp widget_badge(definition) do
    widget = FieldWidgets.resolve(definition)

    if widget && widget != FieldWidgets.default(definition),
      do: definition |> widget_choice(widget) |> elem(0)
  end

  attr :form, :any, required: true
  attr :id, :string, required: true

  # Whether delivery carries a plain-text rendition beside a `:text` field's
  # value (`deliver_plain`). Shown only for that type: on any other, nothing
  # is submitted and `Changes.ClearDeliverPlain` drops a stored `true`.
  # `plain_breaks` sits under it, shown once it is ticked — and cleared with
  # it, by the same change.
  defp deliver_plain_field(assigns) do
    assigns = assign(assigns, :plain?, assigns.form[:deliver_plain].value in [true, "true"])

    ~H"""
    <div :if={to_string(@form[:field_type].value) == "text"} class="space-y-2 self-end text-sm">
      <label for={@id} class="flex items-start gap-2">
        <input type="hidden" name={@form[:deliver_plain].name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@form[:deliver_plain].name}
          value="true"
          checked={@plain?}
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
      <label :if={@plain?} for={"#{@id}-breaks"} class="ml-6 flex items-start gap-2">
        <input type="hidden" name={@form[:plain_breaks].name} value="false" />
        <input
          type="checkbox"
          id={"#{@id}-breaks"}
          name={@form[:plain_breaks].name}
          value="true"
          checked={@form[:plain_breaks].value in [true, "true"]}
          class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary"
        />
        <span>
          {gettext("Keep paragraph breaks")}
          <span class="block text-xs text-base-content/60">
            {gettext(
              "A blank line between paragraphs and a new line for each line break, instead of one line."
            )}
          </span>
        </span>
      </label>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true

  # Whether delivery carries a Portable Text rendition beside a rich `:text`
  # field's value (`deliver_portable`). Shown only for a rich one: on a plain
  # field or any other type nothing is submitted and
  # `Changes.ClearDeliverPortable` drops a stored `true`.
  defp deliver_portable_field(assigns) do
    ~H"""
    <label
      :if={
        to_string(@form[:field_type].value) == "text" and
          to_string(@form[:format].value || "rich") == "rich"
      }
      for={@id}
      class="flex items-start gap-2 self-end text-sm"
    >
      <input type="hidden" name={@form[:deliver_portable].name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@form[:deliver_portable].name}
        value="true"
        checked={@form[:deliver_portable].value in [true, "true"]}
        class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary"
      />
      <span>
        {gettext("Also deliver as Portable Text")}
        <span class="block text-xs text-base-content/60">
          {gettext(
            "APIs add the formatting as structured data under custom_fields_portable, for apps that render rich text natively."
          )}
        </span>
      </span>
    </label>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :nested?, :boolean, default: false

  # The value constraints of a field (#2276), as a fieldset of the inputs its
  # type takes: bounds for a number, length and pattern for text, and whether
  # every value must be unique. The server stays the authority; a constraint
  # the type doesn't take is not offered (and `unpack_validation/1` drops it).
  defp validation_field(assigns) do
    type = to_string(assigns.form[:field_type].value)
    format = assigns.form[:format].value |> to_string() |> format_atom()
    keys = FieldConstraints.allowed_keys(type_atom(type), format)
    multiple? = assigns.form[:multiple].value in [true, "true"]
    validation = FieldConstraints.normalize(assigns.form[:validation].value)

    errors =
      if Phoenix.Component.used_input?(assigns.form[:validation]),
        do: Enum.map(assigns.form[:validation].errors, fn {message, _opts} -> message end),
        else: []

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:keys, keys)
      |> assign(:unique?, "unique" in keys and not assigns.nested? and not multiple?)
      |> assign(:validation, validation)
      |> assign(:errors, errors)
      |> assign(:name, assigns.form[:validation].name)

    ~H"""
    <fieldset
      :if={@keys != []}
      id={@id}
      class="rounded-lg border border-base-content/10 bg-base-200/40 p-3 sm:col-span-2"
    >
      <legend class="px-1 text-sm font-medium">
        {gettext("Validation")}
        <span class="font-normal text-base-content/60">{gettext("(optional)")}</span>
      </legend>
      <div class="grid gap-3 sm:grid-cols-2">
        <.input
          :if={"min" in @keys}
          id={"#{@id}-min"}
          name={"#{@name}[min]"}
          value={@validation["min"]}
          type="number"
          step={if @type == "integer", do: "1", else: "any"}
          label={gettext("Minimum value")}
          placeholder={gettext("No minimum")}
          errors={key_errors(@errors, "min")}
        />
        <.input
          :if={"max" in @keys}
          id={"#{@id}-max"}
          name={"#{@name}[max]"}
          value={@validation["max"]}
          type="number"
          step={if @type == "integer", do: "1", else: "any"}
          label={gettext("Maximum value")}
          placeholder={gettext("No limit")}
          errors={key_errors(@errors, "max")}
        />
        <.input
          :if={"min_length" in @keys}
          id={"#{@id}-min-length"}
          name={"#{@name}[min_length]"}
          value={@validation["min_length"]}
          type="number"
          min="0"
          step="1"
          inputmode="numeric"
          label={gettext("Minimum length")}
          placeholder={gettext("No minimum")}
          errors={key_errors(@errors, "min_length")}
        />
        <.input
          :if={"max_length" in @keys}
          id={"#{@id}-max-length"}
          name={"#{@name}[max_length]"}
          value={@validation["max_length"]}
          type="number"
          min="0"
          step="1"
          inputmode="numeric"
          label={gettext("Maximum length")}
          placeholder={gettext("No limit")}
          errors={key_errors(@errors, "max_length")}
        />
        <.input
          :if={"pattern" in @keys}
          id={"#{@id}-pattern"}
          name={"#{@name}[pattern]"}
          value={@validation["pattern"]}
          label={gettext("Pattern")}
          placeholder="[A-Z]{3}-[0-9]+"
          hint={gettext("A regular expression the whole value must match.")}
          errors={key_errors(@errors, "pattern")}
        />
        <.input
          :if={"pattern_message" in @keys}
          id={"#{@id}-pattern-message"}
          name={"#{@name}[pattern_message]"}
          value={@validation["pattern_message"]}
          label={gettext("Message when it doesn't match")}
          hint={gettext("Shown to editors. Leave empty for the standard message.")}
          errors={key_errors(@errors, "pattern_message")}
        />
        <label :if={@unique?} for={"#{@id}-unique"} class="flex items-start gap-2 text-sm">
          <input type="hidden" name={"#{@name}[unique]"} value="false" />
          <input
            type="checkbox"
            id={"#{@id}-unique"}
            name={"#{@name}[unique]"}
            value="true"
            checked={@validation["unique"] == true}
            class="mt-0.5 size-4 rounded border border-base-content/30 accent-primary"
          />
          <span>
            {gettext("Unique")}
            <span class="block text-xs text-base-content/60">
              {gettext("No two documents of this type and language may hold the same value.")}
            </span>
          </span>
        </label>
      </div>
      <p
        :for={message <- other_errors(@errors, @keys)}
        class="mt-2 text-sm text-error"
        role="alert"
      >
        {message}
      </p>
    </fieldset>
    """
  end

  # A validation error belongs to the input of the constraint it opens with
  # ("pattern is not a valid regular expression: ...").
  defp key_errors(errors, key) do
    Enum.filter(errors, &(constraint_of(&1) == key))
  end

  defp other_errors(errors, keys) do
    Enum.reject(errors, &(constraint_of(&1) in keys))
  end

  defp constraint_of(message) do
    message
    |> String.split(" ", parts: 2)
    |> List.first()
    |> then(&if &1 in FieldConstraints.keys(), do: &1)
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
      <p class="mt-0.5 text-xs text-base-content/60">
        {gettext("To show editors a label, write it after a bar:")}
        <code class="rounded bg-base-200 px-1">clear_heat | Clear heat</code>. {gettext(
          "The value before the bar is what is stored and delivered."
        )}
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
  attr :siblings, :list, default: []
  attr :dynamic, :boolean, default: false

  # The default value, for the types that take one (#1820), in the input that
  # fits the type: a checkbox for yes-or-no, a number box for numbers, a date
  # picker for dates, and one of the options for a select.
  defp default_field(assigns) do
    assigns =
      assigns
      |> assign(:type, to_string(assigns.form[:field_type].value))
      |> assign(:hint, gettext("Used when an editor leaves this field empty."))

    ~H"""
    <.default_source_field
      :if={@dynamic and source_choices(@type) != []}
      form={@form}
      type={@type}
      siblings={@siblings}
    />
    <div
      :if={default?(@form) and not dynamic_default?(@form)}
      class={@type == "boolean" && "self-end"}
    >
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
        options={option_choices(@form)}
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

  attr :form, :any, required: true
  attr :type, :string, required: true
  attr :siblings, :list, required: true

  # Where a new record's value comes from (#2286): a fixed value (the input
  # below), or one of the closed set of dynamic sources the type can take.
  defp default_source_field(assigns) do
    assigns =
      assigns
      |> assign(:choices, source_choices(assigns.type))
      |> assign(:copyable, copyable(assigns.siblings, assigns.type, assigns.form))

    ~H"""
    <div class="grid gap-3 sm:col-span-2 sm:grid-cols-2">
      <.input
        field={@form[:default_source]}
        type="select"
        label={gettext("Default comes from")}
        options={[{gettext("A fixed value"), ""} | @choices]}
        hint={gettext("Applied when a new record leaves this field empty — never on later edits.")}
      />
      <.input
        :if={to_string(@form[:default_source].value) == "copy_of"}
        field={@form[:default_field]}
        type="select"
        label={gettext("Field to copy")}
        options={@copyable}
        prompt={gettext("— Choose a field —")}
      />
    </div>
    """
  end

  defp blank_source(%{"default_source" => ""} = params),
    do: Map.put(params, "default_source", nil)

  defp blank_source(params), do: params

  defp dynamic_default?(form), do: to_string(form[:default_source].value) not in ["", "nil"]

  defp source_choices(type) do
    type
    |> safe_type()
    |> DynamicDefaults.sources_for()
    |> Enum.map(&{source_label(&1), to_string(&1)})
  end

  defp safe_type(type) do
    Enum.find(DynamicDefaults.copy_types(), &(to_string(&1) == type))
  end

  defp source_label(:today), do: gettext("Today's date")
  defp source_label(:now), do: gettext("The current date and time")
  defp source_label(:current_user), do: gettext("The user creating the record")
  defp source_label(:site_locale), do: gettext("The site's default language")
  defp source_label(:copy_of), do: gettext("A copy of another field")

  # The siblings a `:copy_of` may name: the same single-valued type, not
  # itself a copy.
  defp copyable(siblings, type, _form) do
    for s <- siblings,
        to_string(s.field_type) == type,
        not s.multiple,
        s.default_source != :copy_of,
        do: {s.label, s.name}
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
            <.section_input field={@form[:section]} names={@section_names} />
            <.width_input field={@form[:width]} />
            <.localization_input field={@form[:localization]} />
            <.options_field form={@form} id="new-field-options" />
            <.default_field form={@form} siblings={@cond_siblings} dynamic />
            <.text_format_field form={@form} id="new-field-format" />
            <.widget_field form={@form} id="new-field-widget" />
            <.deliver_plain_field form={@form} id="new-field-deliver-plain" />
            <.deliver_portable_field form={@form} id="new-field-deliver-portable" />
            <.validation_field form={@form} id="new-field-validation" />
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
            <.conditions_field
              :if={conditions?(@form)}
              id="new-field-conditions"
              form={@form}
              state={@conds}
              siblings={@cond_siblings}
              ctx="create"
            />
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

          <div
            :for={{scope, definitions} <- @grouped}
            data-field-group={group_heading(scope, @dynamic_types)}
            class="space-y-3"
          >
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
                        :if={definition.multiple and scalar_list?(definition.field_type)}
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
                        :if={widget_badge(definition)}
                        id={"field-#{definition.id}-widget"}
                        title={gettext("The editor input it uses")}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {widget_badge(definition)}
                      </span>
                      <span
                        :if={definition.field_type == :text and definition.deliver_plain}
                        title={gettext("Also delivered as plain text (custom_fields_plain)")}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("plain")}
                      </span>
                      <span
                        :if={definition.field_type == :text and definition.deliver_portable}
                        title={gettext("Also delivered as Portable Text (custom_fields_portable)")}
                        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        {gettext("portable")}
                      </span>
                      <span
                        :if={definition.section}
                        id={"field-#{definition.id}-section"}
                        title={gettext("The section editors see it under")}
                        class="inline-flex items-center gap-1 rounded bg-primary/10 px-1.5 py-0.5 text-xs text-base-content/70"
                      >
                        <.icon name="hero-folder" class="size-3" />{definition.section}
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
                      class="text-xs text-base-content/70"
                    >
                      {gettext("Options")}: {options_summary(definition)}
                    </p>
                    <p
                      :if={definition.field_type == :reference}
                      id={"field-#{definition.id}-links"}
                      class="text-xs text-base-content/70"
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
                      :if={constraints_summary(definition) != ""}
                      id={"field-#{definition.id}-validation"}
                      class="text-xs text-base-content/60"
                    >
                      {constraints_summary(definition)}
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
                      formula_readers={formula_readers(definitions, definition)}
                    />
                  <% end %>
                  <.input field={@edit.form[:help_text]} label={gettext("Help text")} />
                  <.section_input field={@edit.form[:section]} names={@section_names} />
                  <.width_input field={@edit.form[:width]} />
                  <.localization_input field={@edit.form[:localization]} />
                  <.options_field form={@edit.form} id={"edit-field-options-#{@edit.id}"} />
                  <.default_field form={@edit.form} siblings={@edit.cond_siblings} dynamic />
                  <.text_format_field form={@edit.form} id={"edit-field-format-#{@edit.id}"} />
                  <.widget_field form={@edit.form} id={"edit-field-widget-#{@edit.id}"} />
                  <.deliver_plain_field
                    form={@edit.form}
                    id={"edit-field-deliver-plain-#{@edit.id}"}
                  />
                  <.deliver_portable_field
                    form={@edit.form}
                    id={"edit-field-deliver-portable-#{@edit.id}"}
                  />
                  <.validation_field
                    form={@edit.form}
                    id={"edit-field-validation-#{@edit.id}"}
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
                  <.conditions_field
                    :if={conditions?(@edit.form)}
                    id={"edit-field-conditions-#{@edit.id}"}
                    form={@edit.form}
                    state={@edit.conds}
                    siblings={@edit.cond_siblings}
                    ctx="edit"
                  />
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
            <.section_layouts
              :if={section_names(definitions) != []}
              id={"sections-#{group_dom_id(scope)}"}
              scope={owner_param(scope)}
              heading={group_heading(scope, @dynamic_types)}
              names={section_names(definitions)}
              layouts={Map.get(@field_sections, scope, [])}
            />
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

        <section
          :if={@unknown_type != []}
          id="unknown-type-fields"
          class="space-y-3"
          aria-labelledby="unknown-type-fields-heading"
        >
          <div>
            <h2 id="unknown-type-fields-heading" class="flex items-center gap-2 text-lg font-medium">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
              {gettext("Fields of an unknown type")}
            </h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "These fields use a field type this version of Kiln doesn't know — one added by a newer version, or by a plugin that is no longer installed. The editor doesn't show them and published pages leave them out, but records keep their values, and the content API still returns a value unless the field is private. Upgrade Kiln or reinstall the plugin to use them again, or delete them to withdraw their values for good."
              )}
            </p>
          </div>
          <ul class="card divide-y divide-base-content/10 border-warning/40">
            <li :for={definition <- @unknown_type} id={"field-#{definition.id}"} class="p-4">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0 space-y-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="font-medium">{definition.label}</span>
                    <code class="text-xs text-base-content/70">{definition.name}</code>
                    <span class="rounded bg-warning/20 px-1.5 py-0.5 text-xs text-warning">
                      {gettext("unknown type")}
                    </span>
                  </div>
                  <p class="text-xs text-base-content/70">
                    {gettext("On %{owner}, of type %{type}.",
                      owner: unknown_owner(definition, @definitions, @dynamic_types),
                      type: to_string(definition.field_type)
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={definition.id}
                  data-confirm={
                    gettext(
                      "Delete this field and the values records hold in it? This can't be undone."
                    )
                  }
                  aria-label={gettext("Delete field %{name}", name: definition.name)}
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
                {options_summary(link)}
              </span>
              <span
                :if={constraints_summary(link) != ""}
                id={"field-#{link.id}-validation"}
                class="text-xs text-base-content/60"
              >
                {constraints_summary(link)}
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
            open={@open}
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
        open={@open}
      />
    </div>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :group?, :boolean, default: false
  attr :open, :map, required: true

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
      <.validation_field form={@form} id={"#{@id}-validation"} nested? />
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
      <.conditions_field
        :if={@group? and conditions?(@form)}
        id={"#{@id}-conditions"}
        form={@form}
        state={@open.conds}
        siblings={@open.cond_siblings}
        ctx="link"
      />
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

  attr :id, :string, required: true
  attr :scope, :string, required: true, doc: "the type's owner, as its checkbox value"
  attr :heading, :string, required: true, doc: "the type's name, for the panel's label"
  attr :names, :list, required: true, doc: "the sections in use, in editor order"
  attr :layouts, :list, required: true, doc: "the type's stored `FieldSection` rows"

  # A type's Sections panel (#2280): how each section in use is laid out in
  # the content editor. Each row saves as its selects change.
  defp section_layouts(assigns) do
    rows =
      for {name, index} <- Enum.with_index(assigns.names) do
        layout =
          Enum.find(assigns.layouts, %{display: :accordion, initially: :auto}, &(&1.name == name))

        %{name: name, index: index, display: layout.display, initially: layout.initially}
      end

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-heading"} class="card card-pad space-y-3">
      <div class="space-y-1">
        <h4 id={"#{@id}-heading"} class="text-sm font-semibold">
          {gettext("Sections of %{type}", type: @heading)}
        </h4>
        <p class="text-xs text-base-content/70">
          {gettext(
            "An accordion is a heading editors open and close; a fieldset is always open; tabs show one section at a time, and every tab section of the type joins one tab set at the place of the first. Sections keep the order of their first field."
          )}
        </p>
      </div>
      <ul class="divide-y divide-base-content/10">
        <li
          :for={row <- @rows}
          id={"#{@id}-#{row.index}"}
          data-field-section={row.name}
          class="py-3 first:pt-0 last:pb-0"
        >
          <form
            id={"#{@id}-#{row.index}-form"}
            phx-change="section_layout"
            class="grid items-end gap-3 sm:grid-cols-[minmax(0,1fr)_14rem_14rem]"
          >
            <input type="hidden" name="scope" value={@scope} />
            <input type="hidden" name="name" value={row.name} />
            <p class="self-center font-medium break-words">{row.name}</p>
            <.input
              type="select"
              id={"#{@id}-#{row.index}-display"}
              name="section[display]"
              label={gettext("Shown as")}
              value={to_string(row.display)}
              options={display_options()}
            />
            <.input
              type="select"
              id={"#{@id}-#{row.index}-initially"}
              name="section[initially]"
              label={gettext("Starts")}
              value={to_string(row.initially)}
              options={initially_options()}
              disabled={row.display != :accordion}
              title={
                row.display != :accordion &&
                  gettext("Only an accordion opens and closes.")
              }
            />
          </form>
        </li>
      </ul>
    </section>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  # How much of its section's row the field's input takes in the content
  # editor (`width`). Only on these forms: a link field or a group sub-field
  # sits inside its parent's input and keeps the whole of it.
  defp width_input(assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label={gettext("Width")}
      options={[
        {gettext("Full row"), "full"},
        {gettext("Half a row"), "half"},
        {gettext("A third of a row"), "third"}
      ]}
      hint={
        gettext(
          "Narrow fields of the same section sit side by side in the editor; on a small screen each takes the full row."
        )
      }
    />
    """
  end
end
