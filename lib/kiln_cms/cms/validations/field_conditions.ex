defmodule KilnCMS.CMS.Validations.FieldConditions do
  @moduledoc """
  Shape-checks a `FormField.conditions` map at write time so the submission
  pipeline and the public JS can trust it: only `logic`/`rules` keys, a known
  logic mode, list-of-map rules with known operators. A rule with a blank
  `field` is allowed — it's an in-progress row in the builder and evaluates
  as "visible" everywhere.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @operators ~w(eq neq contains empty not_empty gt lt)

  @impl true
  def validate(changeset, _opts, _context) do
    conditions = Ash.Changeset.get_attribute(changeset, :conditions) || %{}

    case check(conditions) do
      :ok ->
        :ok

      {:error, message} ->
        {:error, InvalidAttribute.exception(field: :conditions, message: message)}
    end
  end

  defp check(conditions) when conditions == %{}, do: :ok

  defp check(%{} = conditions) do
    cond do
      Map.keys(conditions) -- ["logic", "rules"] != [] ->
        {:error, "only \"logic\" and \"rules\" are allowed"}

      conditions["logic"] not in [nil, "all", "any"] ->
        {:error, "logic must be \"all\" or \"any\""}

      not is_list(conditions["rules"] || []) ->
        {:error, "rules must be a list"}

      true ->
        Enum.find_value(conditions["rules"] || [], :ok, &broken_rule/1)
    end
  end

  defp check(_not_a_map), do: {:error, "must be a map"}

  defp broken_rule(%{} = rule) do
    cond do
      Map.keys(rule) -- ["field", "operator", "value"] != [] ->
        {:error, "a rule allows only \"field\", \"operator\" and \"value\""}

      not is_binary(rule["field"] || "") ->
        {:error, "a rule's field must be a string"}

      rule["operator"] not in [nil | @operators] ->
        {:error, "unknown operator (allowed: #{Enum.join(@operators, ", ")})"}

      true ->
        nil
    end
  end

  defp broken_rule(_not_a_map), do: {:error, "each rule must be a map"}
end
