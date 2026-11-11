defmodule KilnCMSWeb.ContentEditor.Conditional do
  @moduledoc """
  The wrapper that makes a custom field (or one cell of a group row)
  conditional in the editor (#2277).

  A field with a `visible_when` or `required_when` rule renders inside a
  `phx-hook="FieldConditions"` element carrying the rules as `data-cf-*` JSON.
  The server seeds the starting state (`hidden`, and the `required` on the
  input via `effective/2`); after mount `assets/js/field_conditions.js` owns
  visibility. A field with no rule renders bare, with no wrapper.
  """
  use KilnCMSWeb, :html

  alias KilnCMS.CMS.Conditions

  attr :id, :string, required: true
  attr :definition, :map, required: true
  # The input-name prefix the rules' fields live under.
  attr :prefix, :string, required: true
  # `%{hidden?, required?}` from `Conditions.effective/2`, or nil.
  attr :state, :map, default: nil
  # A group cell leaves `required_when` to the save (a blank row is dropped).
  attr :required, :boolean, default: true
  slot :inner_block, required: true

  def conditional(assigns) do
    definition = assigns.definition
    visible = Conditions.normalize(Map.get(definition, :visible_when))
    required = if assigns.required, do: Conditions.normalize(Map.get(definition, :required_when))

    assigns =
      assigns
      |> assign(:visible_json, visible && Jason.encode!(visible))
      |> assign(:required_json, required && Jason.encode!(required))
      |> assign(:hidden?, assigns.state != nil and assigns.state.hidden?)
      |> assign(:conditional?, visible != nil or required != nil)

    ~H"""
    <div
      :if={@conditional?}
      id={@id}
      phx-hook="FieldConditions"
      data-cf-name={@definition.name}
      data-cf-prefix={@prefix}
      data-cf-visible-when={@visible_json}
      data-cf-required-when={@required_json}
      data-cf-required={@required && to_string(@definition.required == true)}
      aria-hidden={@hidden? && "true"}
      class={if @hidden?, do: "hidden", else: "contents"}
    >
      {render_slot(@inner_block)}
    </div>
    <%= if not @conditional? do %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end

  @doc """
  What each of `definitions` comes to for the form's current values:
  `Conditions.effective/2`, with `values` read by `value_fun`.
  """
  def effective(definitions, value_fun) do
    if Enum.any?(definitions, &Conditions.conditional?/1) do
      values = Map.new(definitions, &{&1.name, value_fun.(&1.name)})
      Conditions.effective(definitions, values)
    else
      %{}
    end
  end

  @doc "`definition` with `required` as the effective state says (a no-op when unconditional)."
  def seed(definition, state) do
    case state do
      %{required?: required?} -> %{definition | required: required?}
      _none -> definition
    end
  end
end
