defmodule KilnCMSWeb.ConditionsBuilderComponents do
  @moduledoc """
  The "Conditions" disclosure on `/editor/fields` (#2277): Show when and
  Required when, each a list of tests on the field's siblings joined by "all"
  or "any". State and serialization live in `KilnCMSWeb.ConditionsBuilder`;
  every input posts under `<form>[conditions]` and the live view turns the
  rows into the `visible_when` / `required_when` params.
  """
  use KilnCMSWeb, :html

  alias KilnCMSWeb.ConditionsBuilder

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :state, :map, required: true
  # The fields beside this one that a test may read.
  attr :siblings, :list, required: true
  # Which form the add/remove buttons act on: "create", "edit" or "link".
  attr :ctx, :string, required: true
  attr :class, :string, default: "sm:col-span-2"

  def conditions_field(assigns) do
    assigns =
      assigns
      |> assign(:count, Enum.sum(for {_rule, rs} <- assigns.state, do: length(rs.rows)))
      |> assign(
        :errors,
        for(
          rule <- ConditionsBuilder.rules(),
          {message, opts} <- assigns.form[String.to_existing_atom(rule)].errors,
          do: {rule, translate_error({message, opts})}
        )
      )

    ~H"""
    <details
      id={@id}
      open={@count > 0 or @errors != [] or Enum.any?(@state, fn {_r, rs} -> rs.nested? end)}
      phx-mounted={JS.ignore_attributes(["open"])}
      class={["group rounded-md border border-base-content/10 bg-base-100", @class]}
    >
      <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 text-sm font-medium">
        <span>
          {gettext("Conditions")}
          <span :if={@count > 0} class="ml-2 text-xs font-normal text-base-content/70">
            {ngettext("%{count} condition", "%{count} conditions", @count)}
          </span>
        </span>
        <.icon
          name="hero-chevron-down-mini"
          class="size-4 text-base-content/70 transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="space-y-4 border-t border-base-content/10 p-3">
        <p :if={@siblings == []} class="text-xs text-base-content/70">
          {gettext(
            "There are no other fields to test yet. Conditions can read a text, number, date, yes/no or choice field beside this one."
          )}
        </p>
        <.rule
          :for={rule <- ConditionsBuilder.rules()}
          id={"#{@id}-#{rule}"}
          rule={rule}
          form={@form}
          state={@state[rule]}
          siblings={@siblings}
          ctx={@ctx}
        />
        <p
          :for={{rule, message} <- @errors}
          id={"#{@id}-#{rule}-error"}
          class="flex items-center gap-1 text-xs text-error"
        >
          <.icon name="hero-exclamation-circle" class="size-4" />
          {rule_title(rule)}: {message}
        </p>
      </div>
    </details>
    """
  end

  defp rule_title("visible_when"), do: gettext("Show when")
  defp rule_title("required_when"), do: gettext("Required when")

  defp rule_hint("visible_when"),
    do:
      gettext(
        "The field is hidden in the editor while this is false. A hidden field keeps its stored value, and the value is still delivered by the API."
      )

  defp rule_hint("required_when"),
    do: gettext("The field must be filled in while this is true.")

  attr :id, :string, required: true
  attr :rule, :string, required: true
  attr :form, :any, required: true
  attr :state, :map, required: true
  attr :siblings, :list, required: true
  attr :ctx, :string, required: true

  defp rule(assigns) do
    ~H"""
    <fieldset id={@id} class="space-y-2">
      <legend class="text-sm font-medium">{rule_title(@rule)}</legend>
      <p class="text-xs text-base-content/70">{rule_hint(@rule)}</p>

      <div
        :if={@state.nested?}
        class="flex flex-wrap items-center justify-between gap-2 rounded border border-base-content/10 bg-base-200/40 p-2 text-xs"
      >
        <span :if={!Map.get(@state, :held?)}>
          {gettext(
            "This field has a nested condition set through the API. It can't be edited here; it stays as it is until you remove it."
          )}
        </span>
        <span :if={Map.get(@state, :held?)}>
          {gettext(
            "This condition reads a field of a type this version of Kiln doesn't know. It can't be edited here; it stays as it is until you remove it."
          )}
        </span>
        <button
          type="button"
          phx-click="cond_clear"
          phx-value-ctx={@ctx}
          phx-value-rule={@rule}
          class="btn btn-sm btn-default"
        >
          {gettext("Remove condition")}
        </button>
      </div>

      <div :if={not @state.nested?} class="space-y-2">
        <div :if={length(@state.rows) > 1} class="flex items-center gap-2 text-sm">
          <.input
            type="select"
            id={"#{@id}-mode"}
            name={"#{@form.name}[conditions][#{@rule}][mode]"}
            value={@state.mode}
            aria-label={gettext("How the conditions combine")}
            options={[
              {gettext("All of these are true"), "all"},
              {gettext("Any of these is true"), "any"}
            ]}
          />
        </div>

        <div
          :for={{row, index} <- Enum.with_index(@state.rows)}
          id={"#{@id}-row-#{index}"}
          class="grid items-start gap-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_minmax(0,1fr)_auto]"
        >
          <.row_inputs
            id={"#{@id}-row-#{index}"}
            base={"#{@form.name}[conditions][#{@rule}][rows][#{index}]"}
            row={row}
            siblings={@siblings}
          />
          <button
            type="button"
            phx-click="cond_remove"
            phx-value-ctx={@ctx}
            phx-value-rule={@rule}
            phx-value-index={index}
            aria-label={gettext("Remove this condition")}
            class="rounded px-1.5 py-2 text-base-content/70 transition-colors hover:bg-base-200 hover:text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>

        <button
          type="button"
          id={"#{@id}-add"}
          phx-click="cond_add"
          phx-value-ctx={@ctx}
          phx-value-rule={@rule}
          disabled={@siblings == []}
          class="btn btn-sm btn-default"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add a condition")}
        </button>
      </div>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :base, :string, required: true
  attr :row, :map, required: true
  attr :siblings, :list, required: true

  defp row_inputs(assigns) do
    type = ConditionsBuilder.type_of(assigns.siblings, assigns.row["field"])
    target = Enum.find(assigns.siblings, &(&1.name == assigns.row["field"]))

    fields =
      for s <- assigns.siblings, do: {s.label, s.name}

    # A rule can still name a field that is gone or no longer eligible.
    fields =
      if target || assigns.row["field"] in [nil, ""],
        do: fields,
        else: fields ++ [{assigns.row["field"], assigns.row["field"]}]

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:target, target)
      |> assign(:fields, fields)
      |> assign(:ops, ops(type))

    ~H"""
    <.input
      type="select"
      id={"#{@id}-field"}
      name={"#{@base}[field]"}
      value={@row["field"]}
      aria-label={gettext("Field")}
      options={@fields}
    />
    <.input
      type="select"
      id={"#{@id}-op"}
      name={"#{@base}[op]"}
      value={@row["op"]}
      aria-label={gettext("Test")}
      options={@ops}
    />
    <div :if={@row["op"] not in ["empty", "not_empty"]}>
      <.value_input
        id={"#{@id}-value"}
        name={"#{@base}[value]"}
        row={@row}
        type={@type}
        target={@target}
      />
    </div>
    <div :if={@row["op"] in ["empty", "not_empty"]} class="hidden sm:block" aria-hidden="true"></div>
    """
  end

  defp ops(type) do
    base = [
      {gettext("is"), "eq"},
      {gettext("is not"), "neq"},
      {gettext("is one of"), "in"},
      {gettext("is empty"), "empty"},
      {gettext("is not empty"), "not_empty"}
    ]

    if type in ConditionsBuilder.ordered_types() do
      base ++ [{gettext("is greater than"), "gt"}, {gettext("is less than"), "lt"}]
    else
      base
    end
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :row, :map, required: true
  attr :type, :atom, default: nil
  attr :target, :any, default: nil

  # A yes/no field is tested with a checkbox, a choice with its options, a
  # list ("is one of") with comma-separated values, anything else with text.
  defp value_input(%{type: :boolean} = assigns) do
    ~H"""
    <label class="flex items-center gap-2 py-2 text-sm">
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@row["value"] == "true"}
        class="size-4 rounded border border-base-content/30 accent-primary"
      />
      {gettext("Ticked")}
    </label>
    """
  end

  defp value_input(%{type: :select, row: %{"op" => op}, target: %{} = target} = assigns)
       when op in ["eq", "neq"] do
    assigns =
      assign(
        assigns,
        :choices,
        for(
          value <- target.options,
          do: {Map.get(target.option_labels || %{}, value, value), value}
        )
      )

    ~H"""
    <.input
      type="select"
      id={@id}
      name={@name}
      value={@row["value"]}
      aria-label={gettext("Value")}
      prompt={gettext("Choose…")}
      options={@choices}
    />
    """
  end

  defp value_input(assigns) do
    ~H"""
    <.input
      type="text"
      id={@id}
      name={@name}
      value={@row["value"]}
      aria-label={gettext("Value")}
      placeholder={if @row["op"] == "in", do: gettext("one, two, three"), else: gettext("Value")}
    />
    """
  end
end
