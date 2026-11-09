defmodule KilnCMS.CMS.FieldWidgets do
  @moduledoc """
  Which **editor input** (widget) a custom field may use (#2284), and which
  one it does.

  A widget is an editor-only choice: a single `:select` as a dropdown, radio
  buttons or a row of buttons; several terms as tags or checkboxes; plain text
  on several lines or one. Storage, coercion and delivery never read it. Each
  field offers a short allow-list worked out from its own settings, and the
  first entry is the type's default, which is today's input:

  | Field                                   | Widgets                               |
  | --------------------------------------- | ------------------------------------- |
  | `:select`, single                       | `dropdown`, `radios`, `buttons`       |
  | `:select`, `multiple`                   | `tags`, `checkboxes` (not with `allow_custom`) |
  | `:text`, `format: :plain`               | `textarea`, `single_line`             |
  | `:reference`, single                    | `autocomplete`, `dropdown`            |
  | a `Kiln.FieldType` with `c:Kiln.FieldType.widgets/1` | what it declares         |
  | a link field or group sub-field         | none                                  |
  | anything else (rich `:text` included)   | none                                  |

  Names are strings, as `FieldDefinition.widget` stores them: a plugin's
  widget is a name the registry answers today, and an atom column would fail
  every read of a definition whose plugin later dropped one.

  A stored widget is a preference, not a promise. `resolve/1` answers the
  stored widget only while the field still offers it, and the type's default
  otherwise; `effective/1` is what the editor renders, which also falls back
  to the default when a radios, buttons or checkboxes field lists more than
  `option_cap/0` options.

  Every function takes a `FieldDefinition` or any map with its keys
  (`:field_type`, `:multiple`, `:allow_custom`, `:format`, `:options`,
  `:link_of_id`, `:group_of_id`, `:widget`); a missing key reads as the
  attribute's default. Labels for the core widgets are translated in the web
  layer; a plugin's own labels come from `plugin_labels/1`.
  """

  alias KilnCMS.CMS.FieldTypes

  @single_select ["dropdown", "radios", "buttons"]
  @multiple_select ["tags", "checkboxes"]
  @plain_text ["textarea", "single_line"]
  @single_reference ["autocomplete", "dropdown"]

  # One input per option: past this many, the editor keeps the default.
  @option_cap 50
  @per_option ["radios", "buttons", "checkboxes"]

  @name ~r/\A[a-z][a-z0-9_]*\z/

  @doc "The widgets `definition` may use, its default first; `[]` when it has no choice."
  @spec allowed(map()) :: [String.t()]
  def allowed(definition), do: definition |> entries() |> Enum.map(&elem(&1, 0))

  @doc "The widget `definition` uses when none is stored, or nil when it has no choice."
  @spec default(map()) :: String.t() | nil
  def default(definition), do: definition |> allowed() |> List.first()

  @doc """
  The widget `definition` uses: its stored `widget` while the field still
  offers it, else the default (nil when the field has no choice).
  """
  @spec resolve(map()) :: String.t() | nil
  def resolve(definition) do
    allowed = allowed(definition)
    widget = Map.get(definition, :widget)

    if widget in allowed, do: widget, else: List.first(allowed)
  end

  @doc """
  The widget the editor renders: `resolve/1`, except that a widget drawing
  one input per option (radios, buttons, checkboxes) falls back to the
  default on a field listing more than `option_cap/0` options.
  """
  @spec effective(map()) :: String.t() | nil
  def effective(definition) do
    widget = resolve(definition)

    if widget in @per_option and too_many_options?(definition),
      do: default(definition),
      else: widget
  end

  @doc "How many options a radios, buttons or checkboxes widget renders before the editor falls back."
  @spec option_cap() :: pos_integer()
  def option_cap, do: @option_cap

  @doc "Whether `widget` draws one input per option, and so is subject to `option_cap/0`."
  @spec per_option?(String.t() | nil) :: boolean()
  def per_option?(widget), do: widget in @per_option

  @doc "Whether `definition` lists more options than a per-option widget renders."
  @spec too_many_options?(map()) :: boolean()
  def too_many_options?(definition),
    do: length(Map.get(definition, :options) || []) > @option_cap

  @doc """
  The labels a plugin field type gave its widgets (`{:stars, "Stars"}`), by
  widget name. Widgets it named without a label, and every core widget, are
  absent.
  """
  @spec plugin_labels(map()) :: %{String.t() => String.t()}
  def plugin_labels(definition) do
    for {name, label} <- entries(definition), is_binary(label), into: %{}, do: {name, label}
  end

  # A link field or group sub-field renders inside its parent's row, which
  # has no room for a choice of input: none, whatever its type.
  defp entries(definition) do
    if sub_field?(definition),
      do: [],
      else: definition |> Map.get(:field_type) |> entries(definition)
  end

  defp entries(:select, definition) do
    cond do
      Map.get(definition, :multiple) != true -> bare(@single_select)
      Map.get(definition, :allow_custom) == true -> bare(@multiple_select -- ["checkboxes"])
      true -> bare(@multiple_select)
    end
  end

  defp entries(:text, definition) do
    if Map.get(definition, :format) == :plain, do: bare(@plain_text), else: []
  end

  defp entries(:reference, definition) do
    if Map.get(definition, :multiple) == true, do: [], else: bare(@single_reference)
  end

  defp entries(type, definition) when is_atom(type) and not is_nil(type),
    do: type |> FieldTypes.get() |> plugin_entries(definition)

  defp entries(_type, _definition), do: []

  defp plugin_entries(nil, _definition), do: []
  defp plugin_entries(module, definition), do: plugin_widgets(module, definition)

  @doc false
  # `{name, label | nil}` for each well-formed widget `module` offers for
  # `definition`. Public so tests can reach a module outside the compiled
  # registry; the host reads it through `allowed/1`.
  @spec plugin_widgets(module(), map()) :: [{String.t(), String.t() | nil}]
  def plugin_widgets(module, definition) do
    if Code.ensure_loaded?(module) and function_exported?(module, :widgets, 1) do
      definition |> module.widgets() |> normalize()
    else
      []
    end
  rescue
    # A plugin's widget list is third-party code: a raise means it offers no
    # choice here, not a failed save or editor. `mix kiln.plugins.doctor`
    # reports it.
    _exception -> []
  end

  # Entries the SDK allows (`name` or `{name, label}`, a machine-name atom);
  # anything else is dropped here and named by the doctor.
  defp normalize(widgets) when is_list(widgets) do
    widgets
    |> Enum.flat_map(&entry/1)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp normalize(_widgets), do: []

  defp entry({name, label}) when is_atom(name) and is_binary(label), do: named(name, label)
  defp entry(name) when is_atom(name), do: named(name, nil)
  defp entry(_other), do: []

  defp named(name, _label) when name in [nil, true, false], do: []

  defp named(name, label) do
    name = Atom.to_string(name)
    if Regex.match?(@name, name), do: [{name, label}], else: []
  end

  defp bare(names), do: Enum.map(names, &{&1, nil})

  defp sub_field?(definition),
    do:
      not is_nil(Map.get(definition, :link_of_id)) or
        not is_nil(Map.get(definition, :group_of_id))
end
