defmodule KilnCMS.CMS.Validations.ConditionsShape do
  @moduledoc """
  The shared shape check for a conditional-logic map (phase 4's
  `%{"logic" => "all"|"any", "rules" => [%{"field","operator","value"}]}`) —
  used by `FieldConditions` (field visibility) and `FormConfirmations`
  (conditional notifications/confirmation variants, phase 6). A rule with a
  blank `field` is allowed: it's an in-progress builder row and evaluates as
  a match-everything no-op.
  """

  @operators ~w(eq neq contains empty not_empty gt lt)

  @doc "The recognised rule operators."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc "Checks one conditions map; `:ok` or `{:error, message}`."
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(conditions) when conditions == %{}, do: :ok

  def check(%{} = conditions) do
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

  def check(_not_a_map), do: {:error, "must be a map"}

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
