defmodule Kiln.Block.Info do
  @moduledoc "Introspection for `Kiln.Block` modules (Kiln v2 — D10)."

  @doc "The single `Kiln.Block.Definition` for a block module (or nil)."
  @spec definition(Ash.Resource.t() | map()) :: Kiln.Block.Definition.t() | nil
  def definition(resource_or_dsl) do
    resource_or_dsl
    |> Spark.Dsl.Extension.get_entities([:kiln_block])
    |> List.first()
  end

  @doc "The block's name / `_type` discriminator."
  @spec name(Ash.Resource.t() | map()) :: atom() | nil
  def name(resource_or_dsl), do: with(%{name: n} <- definition(resource_or_dsl), do: n)

  @doc "The block's schema version (Phase H upcasting)."
  @spec version(Ash.Resource.t() | map()) :: pos_integer() | nil
  def version(resource_or_dsl), do: with(%{version: v} <- definition(resource_or_dsl), do: v)

  @doc "The block's declared fields."
  @spec fields(Ash.Resource.t() | map()) :: [Kiln.Block.Field.t()]
  def fields(resource_or_dsl) do
    case definition(resource_or_dsl) do
      %{fields: fields} -> fields
      _ -> []
    end
  end
end
