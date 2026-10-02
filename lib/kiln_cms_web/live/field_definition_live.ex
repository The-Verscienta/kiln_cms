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
  """
  use KilnCMSWeb, :live_view

  # The field types a typed-in default applies to (#1820): the ones
  # `ApplyCustomFields` coerces a default to. A media item or a reference is
  # picked, not typed; a computed field derives its value; and the composite
  # and plugin types take a shape a single box can't give.
  @default_types ~w(string text url integer float boolean date datetime select)

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition

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
       |> assign(:default_scopes, [])
       |> reset_create_form()
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
     |> assign(:scopes, default_scopes)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- create ----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"field_definition" => params} = event, socket)
      when is_map(params) do
    scopes = selected_scopes(params)
    name_edited? = name_edited?(event["_target"], params, socket.assigns.name_edited?)
    params = if name_edited?, do: params, else: suggest_name(params)
    params = drop_default_on_type_change(params, socket.assigns.form)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.validate(normalize(params, List.first(scopes)))
      |> refuse_duplicates(params, scopes, socket.assigns)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:scopes, scopes)
     |> assign(:name_edited?, name_edited?)
     |> assign(:scope_error, nil)}
  end

  def handle_event("create", %{"field_definition" => params}, socket) when is_map(params) do
    scopes = selected_scopes(params)
    # A submit without a preceding change event (or with the name cleared)
    # still gets the name its label suggests.
    params = if blank?(params["name"]), do: suggest_name(params), else: params
    assigns = socket.assigns
    socket = assign(socket, :scopes, scopes)

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
        {:noreply, assign(socket, :form, form)}

      true ->
        {:noreply, create_all(socket, forms)}
    end
  end

  # --- inline edit -----------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     assign(socket, :edit, %{
       id: id,
       form: edit_form(id, socket.assigns.actor, socket.assigns.current_org)
     })}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :edit, nil)}

  def handle_event("validate_edit", %{"field_definition" => params}, socket)
      when is_map(params) do
    params = drop_default_on_type_change(params, socket.assigns.edit.form)

    edit = %{
      socket.assigns.edit
      | form: AshPhoenix.Form.validate(socket.assigns.edit.form, normalize(params))
    }

    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("save_edit", %{"field_definition" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.edit.form, params: normalize(params)) do
      {:ok, _definition} ->
        {:noreply,
         socket |> assign(:edit, nil) |> load_definitions() |> put_flash(:info, gettext("Saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :edit, %{socket.assigns.edit | form: form})}
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
  end

  # The machine name tracks the label until the admin types into the name
  # input; clearing that input hands it back to the label.
  defp name_edited?(["field_definition", "name"], params, _edited?),
    do: not blank?(params["name"])

  defp name_edited?(_target, _params, edited?), do: edited?

  defp suggest_name(params),
    do: Map.put(params, "name", FieldDefinition.name_from_label(params["label"]))

  defp blank?(value), do: value in [nil, ""]

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
    definitions =
      CMS.list_field_definitions!(
        actor: socket.assigns.actor,
        tenant: socket.assigns.current_org,
        query: [sort: [position: :asc, name: :asc]]
      )

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
    |> unpack_scope(scope)
  end

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
    do: gettext("An image or file from the media library. For a hero image, a logo or a PDF.")

  defp core_type_description(:reference),
    do:
      gettext(
        "A link to another piece of content, of the type you pick below. For a related article, an author or a parent product."
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
    if module && function_exported?(module, :description, 0), do: module.description()
  end

  defp content_type_label(type) do
    case ContentTypes.get(type) do
      %{label: label} -> label
      _ -> Phoenix.Naming.humanize(type)
    end
  end

  # A literal, so the `{{ … }}` never reaches HEEx as markup (curly braces are
  # interpolation in a template, including inside attribute strings).
  defp compute_placeholder, do: "{{ reading_time(body) }} min read"

  attr :form, :any, required: true

  # The formula behind a `:computed` field (#429), shown only for that type —
  # the same conditional treatment `target_type` gets for `:reference`.
  defp compute_field(assigns) do
    ~H"""
    <div :if={computed?(@form)} class="sm:col-span-2">
      <.input
        field={@form[:compute]}
        label={gettext("Formula")}
        placeholder={compute_placeholder()}
      />
      <p class="mt-1 text-xs text-base-content/60">
        {gettext(
          "Derived from the document on every save and every publish — editors can't type into it. Values: %{refs}, plus this type's other fields by name. Functions: %{functions}.",
          refs: Enum.join(Computed.document_refs(), ", "),
          functions: Enum.join(Computed.functions(), ", ")
        )}
      </p>
    </div>
    """
  end

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
        name="field_definition[options]"
        rows="3"
        class="field-input"
      >{options_text(@form)}</textarea>
      <p class="mt-1 text-xs text-base-content/60">
        {gettext("One choice per line. Editors pick one of these.")}
      </p>
    </div>
    """
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

  defp scope_checkbox(assigns) do
    ~H"""
    <label class="flex items-center gap-2 text-sm">
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
              options={Enum.map(@field_types, &{type_label(&1), &1})}
              hint={type_description(@form[:field_type].value, @field_types)}
            />
            <.input
              :if={reference?(@form)}
              field={@form[:target_type]}
              type="select"
              label={gettext("References content of type")}
              options={@target_types}
              prompt={gettext("— Pick a type —")}
            />
            <.compute_field form={@form} />
            <.input field={@form[:help_text]} label={gettext("Help text")} />
            <.options_field form={@form} id="new-field-options" />
            <.default_field form={@form} />
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
                    <p :if={definition.compute} class="text-xs text-base-content/60">
                      {gettext("Formula")}: <code>{definition.compute}</code>
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
                    hint={type_description(@edit.form[:field_type].value, @field_types)}
                  />
                  <.input field={@edit.form[:label]} label={gettext("Label")} />
                  <.input
                    :if={reference?(@edit.form)}
                    field={@edit.form[:target_type]}
                    type="select"
                    label={gettext("References content of type")}
                    options={@target_types}
                    prompt={gettext("— Pick a type —")}
                  />
                  <.compute_field form={@edit.form} />
                  <.input field={@edit.form[:help_text]} label={gettext("Help text")} />
                  <.options_field form={@edit.form} id={"edit-field-options-#{@edit.id}"} />
                  <.default_field form={@edit.form} />
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
end
