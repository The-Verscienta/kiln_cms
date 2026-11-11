defmodule KilnCMS.CMS.Types.CustomFieldCondition do
  @moduledoc """
  One typed condition on an admin-defined custom field: the element type of the
  `custom_where` argument (GraphQL `customWhere`, #2290).

  A condition is a map with the field's `name` and exactly one *kind key*
  (`string`, `int`, `float`, `boolean`, `date`, `date_time`) holding that
  kind's operators. This type only carries the map; it is checked against the
  field's definition by `KilnCMS.CMS.Preparations.CustomFieldQuery`, the one
  place that knows which fields exist and who may see them.

  Absinthe delivers atom keys (`%{name: "price", float: %{gt: 10.0}}`), a
  JSON:API caller string keys; both are accepted and normalised to atoms by the
  preparation.
  """
  use Ash.Type.NewType, subtype_of: :map

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints) when is_map(value), do: {:ok, value}
  def cast_input(_value, _constraints), do: :error

  # The input object itself is defined in `KilnCMSWeb.Graphql.CustomWhere`.
  def graphql_input_type(_constraints), do: :custom_field_condition

  def graphql_type(_constraints), do: :json
end
