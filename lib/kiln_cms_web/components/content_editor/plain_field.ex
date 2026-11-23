defmodule KilnCMSWeb.ContentEditor.PlainField do
  @moduledoc """
  The input of one *plain* custom field (string, text, integer, float,
  boolean, date, datetime, url, select), shared by the two small forms that sit
  inside the editor's own `<form>`: the reference picker's "Add new" and the
  inline record card (#2283).

  Neither is a `<form>` (HTML forbids nesting), so every input carries its own
  `phx-change` (`event`, sent to `target`) and its name lives outside the
  editor's params. Pass `readonly` for a field the actor may see but not write
  (it renders as plain text, never an input), `errors` for messages to show
  under it, and `required` for the marker.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.CMS.FieldDefinition

  attr :id, :string, required: true
  attr :definition, :map, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :event, :string, required: true
  attr :target, :any, required: true
  attr :readonly, :boolean, default: false
  attr :required, :boolean, default: false
  attr :errors, :list, default: []

  @doc "One plain custom field: label, input and its messages."
  def field(%{readonly: true} = assigns) do
    ~H"""
    <div id={@id} data-plain-field={@definition.name} data-readonly>
      <span class="mb-1 block text-xs font-medium">{@definition.label}</span>
      <p class="min-w-0 break-words text-sm text-base-content/80">{display(@definition, @value)}</p>
    </div>
    """
  end

  def field(%{definition: %{field_type: :boolean}} = assigns) do
    ~H"""
    <div data-plain-field={@definition.name}>
      <div class="flex items-center gap-2">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@value == "true" or @value == true}
          phx-change={@event}
          phx-target={@target}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-errors"}
          class="size-4 rounded border-base-content/30"
        />
        <label for={@id} class="text-xs font-medium">
          {@definition.label}<span :if={@required} class="text-error"> *</span>
        </label>
      </div>
      <.errors id={"#{@id}-errors"} errors={@errors} />
    </div>
    """
  end

  def field(%{definition: %{field_type: :select}} = assigns) do
    ~H"""
    <div data-plain-field={@definition.name}>
      <.label_for id={@id} definition={@definition} required={@required} />
      <select
        id={@id}
        name={@name}
        phx-change={@event}
        phx-target={@target}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && "#{@id}-errors"}
        class="field-select"
      >
        <option value="">{gettext("— None —")}</option>
        <option :for={option <- @definition.options} value={option} selected={@value == option}>
          {FieldDefinition.option_label(@definition, option)}
        </option>
      </select>
      <.errors id={"#{@id}-errors"} errors={@errors} />
    </div>
    """
  end

  def field(%{definition: %{field_type: :text}} = assigns) do
    ~H"""
    <div data-plain-field={@definition.name}>
      <.label_for id={@id} definition={@definition} required={@required} />
      <textarea
        id={@id}
        name={@name}
        rows="3"
        phx-change={@event}
        phx-target={@target}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && "#{@id}-errors"}
        class="field-input min-h-16"
      >{@value}</textarea>
      <.errors id={"#{@id}-errors"} errors={@errors} />
    </div>
    """
  end

  def field(assigns) do
    assigns = assign(assigns, :type, input_type(assigns.definition.field_type))

    ~H"""
    <div data-plain-field={@definition.name}>
      <.label_for id={@id} definition={@definition} required={@required} />
      <input
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        step={@definition.field_type == :float && "any"}
        autocomplete="off"
        phx-change={@event}
        phx-target={@target}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && "#{@id}-errors"}
        class="field-input"
      />
      <.errors id={"#{@id}-errors"} errors={@errors} />
    </div>
    """
  end

  @doc "The HTML input type of a plain field type."
  def input_type(:integer), do: "number"
  def input_type(:float), do: "number"
  def input_type(:date), do: "date"
  def input_type(:datetime), do: "datetime-local"
  def input_type(:url), do: "url"
  def input_type(_string), do: "text"

  attr :id, :string, required: true
  attr :definition, :map, required: true
  attr :required, :boolean, default: false

  defp label_for(assigns) do
    ~H"""
    <label for={@id} class="mb-1 block text-xs font-medium">
      {@definition.label}<span :if={@required} class="text-error"> *</span>
    </label>
    """
  end

  attr :id, :string, required: true
  attr :errors, :list, required: true

  defp errors(assigns) do
    ~H"""
    <ul :if={@errors != []} id={@id} class="mt-1 space-y-0.5">
      <li :for={message <- @errors} class="flex items-center gap-1 text-xs text-error">
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" /> {message}
      </li>
    </ul>
    """
  end

  defp display(_definition, value) when value in [nil, ""], do: "—"
  defp display(%{field_type: :boolean}, value) when value in [true, "true"], do: gettext("Yes")
  defp display(%{field_type: :boolean}, value) when value in [false, "false"], do: gettext("No")

  defp display(%{field_type: :select} = definition, value) when is_binary(value),
    do: FieldDefinition.option_label(definition, value)

  defp display(_definition, value) when is_binary(value) or is_number(value), do: to_string(value)
  defp display(_definition, _value), do: "—"
end
