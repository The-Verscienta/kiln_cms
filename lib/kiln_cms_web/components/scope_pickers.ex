defmodule KilnCMSWeb.ScopePickers do
  @moduledoc """
  The team page's pickers for the three granular-RBAC scope axes of a custom
  role or a membership (#2141): which content types it may edit, which it may
  read in the editor, and which fields of each type it may change.

  Rendered from the **stored** value plus whatever the pickers last posted
  (`KilnCMSWeb.ScopeParams.picks/1`), never from the form's attribute values:
  an "Only these…" choice with nothing ticked yet has no attribute value to
  show, and it must stay on screen as the admin left it.

  Two key namespaces meet here and must not be mixed up:

    * the type axes key on the **group** name (`ContentTypes.scope_group_name/1`)
      — a compiled type's own name, and one shared `"entry"` for every custom
      type. So custom types are offered as one choice, never one by one; a
      custom type's own name stored here matches nothing.
    * field grants key on each type's **own** name (`ContentTypes.type_name_for/1`)
      — a custom type's own name, never `"entry"`.

  Nothing stored is dropped because the page does not recognize it: a stored
  type name or grant key this site has no type for, and a stored field name no
  action accepts, are shown (marked "not found") with their current state, so
  saving a form untouched writes back exactly what was there.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [input: 1, icon: 1, translate_error: 1]

  alias KilnCMS.CMS.Changes.EnforceFieldGrants
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.FieldDefinition
  alias Phoenix.LiveView.JS

  @doc """
  The three scope axes for one form.

  `level` sets the wording: on a role an unset axis is "No restriction from
  this role"; on a membership it inherits from the custom role, then the
  account — `inherited` (`%{role: role | nil, user: user}`) supplies what that
  currently resolves to.
  """
  attr :id, :string, required: true, doc: "unique per form; every element id derives from it"
  attr :form, Phoenix.HTML.Form, required: true
  attr :level, :atom, values: [:role, :member], required: true
  attr :stored, :map, required: true, doc: "`KilnCMSWeb.ScopeParams.stored/1`"
  attr :picks, :map, default: nil, doc: "`KilnCMSWeb.ScopeParams.picks/1` of the last post"
  attr :errors, :map, default: %{}, doc: "`KilnCMSWeb.ScopeParams.normalize/2` errors"

  attr :catalog, :map,
    required: true,
    doc:
      "`catalog/2`: `%{compiled: [descriptor], dynamic: [descriptor], fields: %{type => [def]}}`"

  attr :inherited, :map, default: nil

  def scope_pickers(assigns) do
    assigns =
      assigns
      |> assign(
        :axes,
        Enum.map([:editable_types, :readable_types], &type_axis_assigns(assigns, &1))
      )
      |> assign(:grants, grants_assigns(assigns))

    ~H"""
    <div id={"#{@id}-scope"} class="space-y-4">
      <.type_axis :for={axis <- @axes} {axis} />
      <.field_grants {@grants} />
    </div>
    """
  end

  # --- type axes ---------------------------------------------------------------

  defp type_axis_assigns(assigns, axis) do
    stored = Map.fetch!(assigns.stored, axis)
    pick = assigns.picks && Map.get(assigns.picks, axis)

    mode =
      cond do
        pick -> pick.mode
        stored == [] -> "all"
        true -> "only"
      end

    checked = (pick && pick.values) || stored
    seen = Enum.uniq(stored ++ checked)
    choices = type_choices(assigns.catalog, seen)
    known = Enum.map(choices, &elem(&1, 1))

    %{
      axis: axis,
      base: "#{assigns.id}-#{axis_slug(axis)}",
      name: assigns.form.name,
      level: assigns.level,
      mode: mode,
      checked: checked,
      choices: choices,
      stale: seen -- known,
      dynamic_labels: Enum.map(assigns.catalog.dynamic, & &1.label),
      inherited: inherited_types(assigns.inherited, axis),
      error: Map.get(assigns.errors, axis),
      field_errors: form_errors(assigns.form, axis)
    }
  end

  # Compiled types by their own name, then — when the site has custom types, or
  # one is already stored — the shared group key every custom type answers to.
  defp type_choices(catalog, seen) do
    compiled = Enum.map(catalog.compiled, &{&1.label, to_string(&1.type)})

    if catalog.dynamic != [] or "entry" in seen,
      do: compiled ++ [{gettext("Custom content types (all of them)"), "entry"}],
      else: compiled
  end

  attr :axis, :atom, required: true
  attr :base, :string, required: true
  attr :name, :string, required: true
  attr :level, :atom, required: true
  attr :mode, :string, required: true
  attr :checked, :list, required: true
  attr :choices, :list, required: true
  attr :stale, :list, required: true
  attr :dynamic_labels, :list, required: true
  attr :inherited, :any, required: true
  attr :error, :atom, default: nil
  attr :field_errors, :list, default: []

  defp type_axis(assigns) do
    ~H"""
    <fieldset
      id={@base}
      class="space-y-2"
      aria-describedby={"#{@base}-hint"}
    >
      <legend class="mb-1 block text-sm font-medium text-base-content">
        {axis_legend(@axis)}
      </legend>
      <p id={"#{@base}-hint"} class="text-xs text-base-content/60">
        {axis_hint(@axis, @level)}
      </p>
      <div class="flex flex-wrap gap-x-4 gap-y-1">
        <label
          :for={
            {value, label} <- [{"all", unset_label(@level)}, {"only", gettext("Only these types")}]
          }
          for={"#{@base}-mode-#{value}"}
          class="inline-flex cursor-pointer items-center gap-2 text-sm"
        >
          <input
            type="radio"
            id={"#{@base}-mode-#{value}"}
            name={"#{@name}[#{mode_param(@axis)}]"}
            value={value}
            checked={@mode == value}
            class="field-checkbox size-4"
          />
          {label}
        </label>
      </div>
      <p :if={@level == :member and @mode == "all"} class="text-xs text-base-content/60">
        {gettext("Currently inherited: %{value}", value: inherited_types_text(@inherited))}
      </p>

      <div :if={@mode == "only"} class="space-y-2">
        <%!-- Sentinel so an all-unticked list still posts the key — and is
              refused, rather than read as "no restriction". --%>
        <input type="hidden" name={"#{@name}[#{@axis}][]"} value="" />
        <div class="flex flex-wrap gap-2">
          <.choice
            :for={{{label, value}, index} <- Enum.with_index(@choices)}
            id={"#{@base}-type-#{index}"}
            name={"#{@name}[#{@axis}][]"}
            value={value}
            checked={value in @checked}
            label={label}
          />
        </div>
        <p
          :if={"entry" in Enum.map(@choices, &elem(&1, 1)) and @dynamic_labels != []}
          class="text-xs text-base-content/60"
        >
          {gettext(
            "Custom content types (all of them) covers every custom type on this site: %{types}. They can't be picked one by one here.",
            types: Enum.join(@dynamic_labels, ", ")
          )}
        </p>
        <div :if={@stale != []} class="space-y-1">
          <p class="text-xs font-medium text-base-content/70">{gettext("Not found on this site")}</p>
          <p class="text-xs text-base-content/70">
            {gettext(
              "These stored names match no content type here, so they allow nothing. A custom type's own name never matches on this list — use Custom content types (all of them). Untick a name to remove it."
            )}
          </p>
          <div class="flex flex-wrap gap-2">
            <.choice
              :for={{value, index} <- Enum.with_index(@stale)}
              id={"#{@base}-stale-#{index}"}
              name={"#{@name}[#{@axis}][]"}
              value={value}
              checked={value in @checked}
              label={gettext("%{name} (not found)", name: value)}
            />
          </div>
        </div>
      </div>

      <.picker_error :if={@error} message={type_error(@level)} />
      <.picker_error :for={message <- @field_errors} message={message} />
    </fieldset>
    """
  end

  # --- field grants ------------------------------------------------------------

  defp grants_assigns(assigns) do
    %{catalog: catalog, stored: %{field_grants: stored} = stored_all} = assigns
    stored_read = Map.get(stored_all, :field_read_grants, %{})
    picks = (assigns.picks && assigns.picks.field_grants) || %{}
    read_picks = (assigns.picks && Map.get(assigns.picks, :field_read_grants)) || %{}

    known =
      Enum.map(catalog.compiled, &{:compiled, to_string(&1.type), &1.label, fields_of(&1)}) ++
        Enum.map(catalog.dynamic, &{:dynamic, to_string(&1.type), &1.label, fields_of(&1)})

    known_keys = Enum.map(known, &elem(&1, 1))

    stale =
      for key <- Enum.sort(Enum.uniq(Map.keys(stored) ++ Map.keys(stored_read))),
          key not in known_keys,
          do: key

    rows =
      (known ++ Enum.map(stale, &{:stale, &1, &1, []}))
      |> Enum.with_index()
      |> Enum.map(fn {{group, key, label, fields}, index} ->
        definitions = Map.get(Map.get(catalog, :fields, %{}), key, [])

        assigns
        |> grant_row(group, key, label, fields, index, Map.get(stored, key), picks[key])
        |> Map.merge(custom_assigns(definitions))
        |> Map.merge(read_assigns(assigns, key, definitions, stored_read, read_picks))
        |> then(fn row ->
          %{row | other: row.other -- Enum.map(row.custom, & &1.key)}
        end)
      end)

    %{
      base: "#{assigns.id}-grants",
      level: assigns.level,
      rows: rows,
      field_errors:
        form_errors(assigns.form, :field_grants) ++ form_errors(assigns.form, :field_read_grants)
    }
  end

  # The individual custom fields a write grant can name (#2281): top-level
  # fields by name, a group's sub-fields beneath it. Computed fields are the
  # system's, and link fields ride on their reference, so neither is offered.
  defp custom_assigns(definitions) do
    custom =
      for %{field_type: type} = definition <- top_level(definitions),
          type != :computed,
          entry <- [entry(definition, 0) | group_entries(definition)],
          do: entry

    %{custom: custom}
  end

  defp group_entries(%{field_type: :group} = group) do
    for sub <- FieldDefinition.group_fields(group),
        sub.field_type != :computed,
        do: %{
          key: FieldAccess.key([group.name, sub.name]),
          label: definition_label(sub),
          depth: 1
        }
  end

  defp group_entries(_definition), do: []

  defp entry(definition, depth),
    do: %{
      key: FieldAccess.key([definition.name]),
      label: definition_label(definition),
      depth: depth
    }

  defp definition_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp definition_label(%{name: name}), do: name

  defp top_level(definitions),
    do: Enum.filter(definitions, &(is_nil(&1.link_of_id) and is_nil(&1.group_of_id)))

  # The read picker (#2281): only private top-level fields can be hidden, so
  # only those are offered; the bare key stands for all of them.
  defp read_assigns(assigns, key, definitions, stored_read, read_picks) do
    stored = Map.get(stored_read, key)
    pick = read_picks[key]

    private =
      for %{private: true} = definition <- top_level(definitions), do: entry(definition, 0)

    checked = picked_values(pick, stored)
    offered = ["custom_fields" | Enum.map(private, & &1.key)]

    %{
      read_mode: picked_mode(pick, stored),
      read_private: private,
      read_checked: checked,
      read_other: Enum.uniq((stored || []) ++ checked) -- offered,
      read_error: Map.get(assigns.errors, {:read_grant, key}),
      read_shown?: private != [] or not is_nil(stored) or not is_nil(pick)
    }
  end

  defp picked_mode(%{mode: mode}, _stored), do: mode
  defp picked_mode(_pick, nil), do: "any"
  defp picked_mode(_pick, []), do: "none"
  defp picked_mode(_pick, _stored), do: "only"

  defp picked_values(%{values: values}, _stored) when values not in [nil, false], do: values
  defp picked_values(_pick, stored), do: stored || []

  defp fields_of(descriptor), do: EnforceFieldGrants.grantable_fields(descriptor)

  defp grant_row(assigns, group, key, label, fields, index, stored, pick) do
    mode =
      cond do
        pick -> pick.mode
        is_nil(stored) -> "any"
        stored == [] -> "none"
        true -> "only"
      end

    checked = (pick && pick.values) || stored || []

    %{
      group: group,
      key: key,
      label: label,
      index: index,
      base: "#{assigns.id}-grant-#{index}",
      name: assigns.form.name,
      mode: mode,
      fields: fields,
      checked: checked,
      other: Enum.uniq((stored || []) ++ checked) -- fields,
      inherited: inherited_grant(assigns.inherited, key),
      error: Map.get(assigns.errors, {:grant, key})
    }
  end

  attr :base, :string, required: true
  attr :level, :atom, required: true
  attr :rows, :list, required: true
  attr :field_errors, :list, default: []

  defp field_grants(assigns) do
    ~H"""
    <fieldset id={@base} class="space-y-2" aria-describedby={"#{@base}-hint"}>
      <legend class="mb-1 block text-sm font-medium text-base-content">
        {gettext("Field grants")}
      </legend>
      <p id={"#{@base}-hint"} class="text-xs text-base-content/60">
        {grants_hint(@level)}
      </p>
      <div
        :for={
          {group, heading} <- [
            {:compiled, gettext("Built-in")},
            {:dynamic, gettext("Custom")},
            {:stale, gettext("Not found on this site")}
          ]
        }
        :if={Enum.any?(@rows, &(&1.group == group))}
        class="space-y-2"
      >
        <p class="text-xs font-medium uppercase tracking-wide text-base-content/60">{heading}</p>
        <p :if={group == :stale} class="text-xs text-base-content/60">
          {gettext(
            "Grants stored for types this site doesn't have. Setting one to no restriction deletes it — and a type created later with that name would then not be field-restricted."
          )}
        </p>
        <.grant_row :for={row <- @rows} :if={row.group == group} row={row} level={@level} />
      </div>
      <.picker_error :for={message <- @field_errors} message={message} />
    </fieldset>
    """
  end

  attr :row, :map, required: true
  attr :level, :atom, required: true

  defp grant_row(assigns) do
    ~H"""
    <details
      id={@row.base}
      open={@row.mode != "any"}
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group rounded-md border border-base-content/10 bg-base-100"
    >
      <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 text-sm">
        <span>
          <span class="font-medium">
            {if @row.group == :stale,
              do: gettext("%{name} (type not found)", name: @row.key),
              else: @row.label}
          </span>
          <span class="ml-2 text-xs text-base-content/60">{mode_summary(@row, @level)}</span>
        </span>
        <.icon
          name="hero-chevron-down-mini"
          class="size-4 text-base-content/50 transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="space-y-2 border-t border-base-content/10 px-3 py-3">
        <%!-- The key travels as a value, by position — never inside a param
              name or an id (a stored key may be anything). --%>
        <input type="hidden" name={"#{@row.name}[grant_type][#{@row.index}]"} value={@row.key} />
        <.input
          type="select"
          id={"#{@row.base}-mode"}
          name={"#{@row.name}[grant_mode][#{@row.index}]"}
          value={@row.mode}
          options={grant_mode_options(@level)}
          label={grant_mode_label(@row)}
          hint={grant_mode_hint(@row.mode, @level)}
        />
        <p :if={@level == :member and @row.mode == "any"} class="text-xs text-base-content/60">
          {gettext("Currently inherited: %{value}", value: grant_text(@row.inherited))}
        </p>

        <fieldset :if={@row.mode == "only"} class="space-y-2">
          <legend class="text-xs font-medium text-base-content/70">
            {gettext("Fields of %{type} they may change", type: @row.label)}
          </legend>
          <input type="hidden" name={"#{@row.name}[grant_fields][#{@row.index}][]"} value="" />
          <div class="flex flex-wrap gap-2">
            <.choice
              :for={{field, index} <- Enum.with_index(@row.fields)}
              id={"#{@row.base}-field-#{index}"}
              name={"#{@row.name}[grant_fields][#{@row.index}][]"}
              value={field}
              checked={field in @row.checked}
              label={field_label(field)}
              raw={field}
            />
          </div>
          <div :if={@row.custom != []} class="space-y-1">
            <p class="text-xs font-medium text-base-content/70">
              {gettext("Individual custom fields")}
            </p>
            <p class="text-xs text-base-content/70">
              {gettext(
                "Tick Custom fields (all of them) above for every custom field, or pick individual ones here. A group's own box lets them add, remove and reorder its rows; a field under it lets them change just that field in every row. With any of these ticked, creating a document is held to them too."
              )}
            </p>
            <ul class="space-y-1">
              <li
                :for={{entry, index} <- Enum.with_index(@row.custom)}
                class={[entry.depth > 0 && "ml-6"]}
              >
                <label
                  for={"#{@row.base}-custom-#{index}"}
                  class="inline-flex cursor-pointer items-center gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    id={"#{@row.base}-custom-#{index}"}
                    name={"#{@row.name}[grant_fields][#{@row.index}][]"}
                    value={entry.key}
                    checked={entry.key in @row.checked}
                    class="field-checkbox size-4"
                  />
                  {entry.label}
                  <code class="font-mono text-xs text-base-content/70">{entry.key}</code>
                </label>
              </li>
            </ul>
          </div>
          <div :if={@row.other != []} class="space-y-1">
            <p class="text-xs font-medium text-base-content/70">{gettext("Other stored fields")}</p>
            <p class="text-xs text-base-content/60">
              {gettext(
                "Stored for this type, but not a field that can be granted here, so they allow nothing. Untick one to remove it."
              )}
            </p>
            <div class="flex flex-wrap gap-2">
              <.choice
                :for={{field, index} <- Enum.with_index(@row.other)}
                id={"#{@row.base}-other-#{index}"}
                name={"#{@row.name}[grant_fields][#{@row.index}][]"}
                value={field}
                checked={field in @row.checked}
                label={gettext("%{name} (not found)", name: field)}
              />
            </div>
          </div>
        </fieldset>

        <.picker_error
          :if={@row.error}
          message={gettext("Pick at least one field, or choose No fields.")}
        />

        <.read_picker :if={@row.read_shown?} row={@row} level={@level} />
      </div>
    </details>
    """
  end

  attr :row, :map, required: true
  attr :level, :atom, required: true

  # Which private custom fields of the type they can see (#2281).
  defp read_picker(assigns) do
    ~H"""
    <div class="space-y-2 border-t border-base-content/10 pt-3">
      <.input
        type="select"
        id={"#{@row.base}-read-mode"}
        name={"#{@row.name}[grant_read_mode][#{@row.index}]"}
        value={@row.read_mode}
        options={read_mode_options(@level)}
        label={gettext("Custom fields they can read")}
        hint={
          gettext(
            "Only private custom fields can be hidden: everyone who can edit this type already reads the others. A field they may change is always readable."
          )
        }
      />
      <fieldset :if={@row.read_mode == "only"} class="space-y-2">
        <legend class="text-xs font-medium text-base-content/70">
          {gettext("Private fields of %{type} they can read", type: @row.label)}
        </legend>
        <input type="hidden" name={"#{@row.name}[grant_read_fields][#{@row.index}][]"} value="" />
        <div class="flex flex-wrap gap-2">
          <.choice
            id={"#{@row.base}-read-all"}
            name={"#{@row.name}[grant_read_fields][#{@row.index}][]"}
            value="custom_fields"
            checked={"custom_fields" in @row.read_checked}
            label={gettext("All private fields")}
            raw="custom_fields"
          />
          <.choice
            :for={{entry, index} <- Enum.with_index(@row.read_private)}
            id={"#{@row.base}-read-#{index}"}
            name={"#{@row.name}[grant_read_fields][#{@row.index}][]"}
            value={entry.key}
            checked={entry.key in @row.read_checked}
            label={entry.label}
            raw={entry.key}
          />
        </div>
        <div :if={@row.read_other != []} class="space-y-1">
          <p class="text-xs font-medium text-base-content/70">{gettext("Other stored fields")}</p>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Stored for this type, but not a private field here, so they allow nothing. Untick one to remove it."
            )}
          </p>
          <div class="flex flex-wrap gap-2">
            <.choice
              :for={{field, index} <- Enum.with_index(@row.read_other)}
              id={"#{@row.base}-read-other-#{index}"}
              name={"#{@row.name}[grant_read_fields][#{@row.index}][]"}
              value={field}
              checked={field in @row.read_checked}
              label={gettext("%{name} (not found)", name: field)}
            />
          </div>
        </div>
      </fieldset>
      <.picker_error
        :if={@row.read_error}
        message={gettext("Pick at least one field, or choose None of them.")}
      />
    </div>
    """
  end

  defp read_mode_options(level) do
    [
      {if(level == :role, do: gettext("All private fields"), else: unset_label(level)), "any"},
      {gettext("Only these private fields"), "only"},
      {gettext("None of them"), "none"}
    ]
  end

  # --- shared pieces -----------------------------------------------------------

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :raw, :string, default: nil

  defp choice(assigns) do
    ~H"""
    <label
      for={@id}
      class={[
        "inline-flex cursor-pointer items-center gap-2 rounded-full border px-3 py-1 text-sm transition-colors",
        if(@checked,
          do: "border-primary bg-primary/5 text-base-content",
          else: "border-base-content/15 text-base-content/80 hover:border-base-content/30"
        )
      ]}
    >
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        class="field-checkbox size-3.5"
      />
      {@label}
      <code :if={@raw} class="font-mono text-xs text-base-content/50">{@raw}</code>
    </label>
    """
  end

  attr :message, :string, required: true

  defp picker_error(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-sm text-error" role="alert">
      <.icon name="hero-exclamation-circle" class="size-4" />{@message}
    </p>
    """
  end

  defp form_errors(form, field) do
    if Phoenix.Component.used_input?(form[field]),
      do: Enum.map(form[field].errors, &translate_error/1),
      else: []
  end

  defp axis_slug(:editable_types), do: "editable"
  defp axis_slug(:readable_types), do: "readable"

  defp mode_param(:editable_types), do: "editable_mode"
  defp mode_param(:readable_types), do: "readable_mode"

  defp axis_legend(:editable_types), do: gettext("Content types they may edit")
  defp axis_legend(:readable_types), do: gettext("Content types they may read in the editor")

  defp axis_hint(:editable_types, :role),
    do: gettext("Which types members with this role may create and edit.")

  defp axis_hint(:editable_types, :member),
    do:
      gettext(
        "Which types this member may create and edit. Only these types replaces their custom role's list — it can widen past it."
      )

  defp axis_hint(:readable_types, :role),
    do:
      gettext(
        "Which unpublished content they see in the editor. Types they may edit are always readable."
      )

  defp axis_hint(:readable_types, :member),
    do:
      gettext(
        "Which unpublished content they see in the editor. Types they may edit are always readable. Only these types replaces their custom role's list — it can widen past it."
      )

  defp unset_label(:role), do: gettext("No restriction from this role")
  defp unset_label(:member), do: gettext("Inherit (custom role, then account)")

  defp type_error(:role),
    do: gettext("Pick at least one type, or choose No restriction from this role.")

  defp type_error(:member), do: gettext("Pick at least one type, or choose Inherit.")

  defp grants_hint(:role),
    do:
      gettext(
        "For each content type, which fields members with this role may change on existing documents. Creating documents and workflow steps are not affected, and any grant on a type also refuses restoring an old version of it."
      )

  defp grants_hint(:member),
    do:
      gettext(
        "For each content type, which fields this member may change on existing documents. Only these fields replaces their custom role's grant for that type, and No fields overrides it. Creating documents and workflow steps are not affected, and any grant on a type also refuses restoring an old version of it."
      )

  defp grant_mode_options(level) do
    [
      {unset_label(level), "any"},
      {gettext("Only these fields"), "only"},
      {gettext("No fields (can't change existing documents)"), "none"}
    ]
  end

  defp grant_mode_label(%{label: label}), do: gettext("Fields of %{type}", type: label)

  defp grant_mode_hint("none", _level),
    do:
      gettext(
        "Existing documents of this type can't be changed at all: duplicates and translations carry no fields, and restoring a version is refused. Creating new ones and workflow steps still work."
      )

  defp grant_mode_hint(_mode, _level), do: nil

  defp mode_summary(%{mode: "any"}, :role), do: gettext("no restriction")
  defp mode_summary(%{mode: "any"}, :member), do: gettext("inherited")
  defp mode_summary(%{mode: "none"}, _level), do: gettext("no fields")
  defp mode_summary(%{mode: "only", checked: []}, _level), do: gettext("nothing picked yet")
  defp mode_summary(%{mode: "only", checked: checked}, _level), do: Enum.join(checked, ", ")

  defp field_label("custom_fields"), do: gettext("Custom fields (all of them)")
  defp field_label(field), do: Phoenix.Naming.humanize(field)

  # What an unset member axis falls through to: the custom role's list when it
  # has one, else the account's (first non-empty wins, as in `Scoping`).
  defp inherited_types(nil, _axis), do: nil

  defp inherited_types(%{} = inherited, axis) do
    Enum.find_value([inherited[:role], inherited[:user]], [], fn
      %{} = source -> non_empty(Map.get(source, axis))
      _ -> nil
    end)
  end

  defp non_empty([_ | _] = list), do: list
  defp non_empty(_other), do: nil

  defp inherited_types_text([]), do: gettext("no restriction")
  defp inherited_types_text(types), do: Enum.join(types, ", ")

  # A grant key falls through on absence only — `[]` stops it (as in `Scoping`).
  defp inherited_grant(nil, _key), do: nil

  defp inherited_grant(%{} = inherited, key) do
    Enum.find_value([inherited[:role], inherited[:user]], fn
      %{field_grants: %{} = grants} -> Map.get(grants, key)
      _ -> nil
    end)
  end

  defp grant_text(nil), do: gettext("no restriction")
  defp grant_text([]), do: gettext("no fields")
  defp grant_text(fields), do: Enum.join(fields, ", ")

  @doc """
  A field-grants map in words, for a role or member row: each type by its label
  (stored keys this site has no type for by their key) and `[]` as "none".
  """
  @spec grants_summary(map(), map()) :: String.t() | nil
  def grants_summary(grants, catalog) when is_map(grants) and map_size(grants) > 0 do
    labels = Map.new(catalog.compiled ++ catalog.dynamic, &{to_string(&1.type), &1.label})

    parts =
      grants
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("; ", fn {key, fields} ->
        "#{Map.get(labels, key, key)}: #{grant_fields_text(fields)}"
      end)

    gettext("fields: %{grants}", grants: parts)
  end

  def grants_summary(_grants, _catalog), do: nil

  @doc """
  A field-read-grants map in words, for a role or member row (the twin of
  `grants_summary/2`).
  """
  @spec read_grants_summary(map() | nil, map()) :: String.t() | nil
  def read_grants_summary(grants, catalog) when is_map(grants) and map_size(grants) > 0 do
    labels = Map.new(catalog.compiled ++ catalog.dynamic, &{to_string(&1.type), &1.label})

    parts =
      grants
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("; ", fn {key, fields} ->
        "#{Map.get(labels, key, key)}: #{grant_fields_text(fields)}"
      end)

    gettext("can read: %{grants}", grants: parts)
  end

  def read_grants_summary(_grants, _catalog), do: nil

  defp grant_fields_text([]), do: gettext("none")
  defp grant_fields_text(fields), do: Enum.join(fields, ", ")

  @doc """
  The catalog `scope_pickers/1` offers for `org`: the content types, and each
  type's custom field definitions (read as `actor`) under its grant key, for
  the per-field pickers (#2281).
  """
  @spec catalog(term(), map() | nil) :: map()
  def catalog(org, actor \\ nil) do
    compiled = KilnCMS.CMS.ContentTypes.all()
    dynamic = KilnCMS.CMS.ContentTypes.dynamic_all(org)
    org_id = KilnCMS.Accounts.org_id(org)

    fields =
      if actor,
        do: Map.new(compiled ++ dynamic, &{to_string(&1.type), definitions(&1, actor, org_id)}),
        else: %{}

    %{compiled: compiled, dynamic: dynamic, fields: fields}
  end

  defp definitions(%{source: :dynamic, definition: %{id: id}}, actor, org_id),
    do: KilnCMS.CMS.field_definitions_for_definition!(id, actor: actor, tenant: org_id)

  defp definitions(%{type: type}, actor, org_id),
    do: KilnCMS.CMS.field_definitions_for!(type, actor: actor, tenant: org_id)
end
