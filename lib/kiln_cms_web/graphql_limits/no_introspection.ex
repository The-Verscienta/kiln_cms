defmodule KilnCMSWeb.GraphqlLimits.NoIntrospection do
  @moduledoc """
  Refuses schema introspection (`__schema`, `__type`) where it is disabled
  (`KilnCMSWeb.GraphqlLimits.introspection_enabled?/0`: off in production), so a
  client cannot download the schema's full map. That map includes the write
  mutations (#330). `__typename` is unaffected.

  The check reads the parsed document, not the request text. Each operation in a
  batched `/gql` body and each `/ws/gql` document goes through this pipeline, so
  each one is checked. Aliases rename a field's result key and leave its name
  alone, so an alias cannot evade the check. A match inside a fragment, even one
  no operation spreads, is refused too.
  """
  use Absinthe.Phase

  alias Absinthe.Blueprint

  @meta_fields ["__schema", "__type"]

  @impl Absinthe.Phase
  def run(%Blueprint{} = blueprint, _opts) do
    if KilnCMSWeb.GraphqlLimits.introspection_enabled?() do
      {:ok, blueprint}
    else
      {:ok, Blueprint.prewalk(blueprint, &refuse/1)}
    end
  end

  defp refuse(%Blueprint.Document.Field{name: name} = field) when name in @meta_fields do
    field
    |> flag_invalid(:introspection_disabled)
    |> put_error(%Absinthe.Phase.Error{
      phase: __MODULE__,
      message: "GraphQL introspection is disabled",
      locations: [field.source_location]
    })
  end

  defp refuse(node), do: node
end
