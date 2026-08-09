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

  @doc """
  The block's **translatable** fields, as `{name, :text | :rich_text | {:map_keys, [atom]}}`
  in declaration order (#502).

  This is what the XLIFF exporter (`KilnCMS.CMS.Xliff`) segments a block into,
  and it is deliberately a property of the *field*, not a table in the exporter:
  a plugin block (D18) declares its own prose the same way a core one does, and
  gets the same vendor round-trip for free.

  The default is derived from the field type — `:string` and `:rich_text` carry
  prose, nothing else does — because that is right for the overwhelming
  majority of fields. It is wrong in one direction that matters: a `:string`
  holding an identifier (`media_id`, `form_slug`, a layout keyword) is not
  prose, and shipping one to a translation vendor invites a "translation" that
  breaks the block on the way back in. Those fields say `translatable: false`
  explicitly.

  `{:array, :map}` fields have no derivable answer at all — the map's keys are
  the block's own convention — so they are opt-in by naming the keys:
  `field :items, {:array, :map}, translatable: [:question, :answer]`.

  The third answer is `:unsupported` — prose this exporter cannot round-trip
  safely (raw HTML, an opaque legacy payload). It is reported separately from
  `false` because the two mean different things to an operator: `false` says
  "there was never anything here to translate", `:unsupported` says "there is
  text here and it is not in the file you are about to send out".
  """
  @spec translatable(Ash.Resource.t() | map()) :: [{atom(), atom() | {:map_keys, [atom()]}}]
  def translatable(resource_or_dsl) do
    resource_or_dsl
    |> fields()
    |> Enum.flat_map(fn field ->
      case translatable_kind(field) do
        nil -> []
        kind -> [{field.name, kind}]
      end
    end)
  end

  defp translatable_kind(%{translatable: :unsupported}), do: :unsupported
  defp translatable_kind(%{translatable: false}), do: nil
  defp translatable_kind(%{translatable: []}), do: nil
  defp translatable_kind(%{translatable: [_ | _] = keys}), do: {:map_keys, keys}
  defp translatable_kind(%{translatable: true, type: :rich_text}), do: :rich_text
  defp translatable_kind(%{translatable: true}), do: :text
  defp translatable_kind(%{type: :rich_text}), do: :rich_text
  defp translatable_kind(%{type: :string}), do: :text
  defp translatable_kind(_field), do: nil

  @doc "The block's declared schema migrations (Phase H upcasting)."
  @spec migrations(Ash.Resource.t() | map()) :: [Kiln.Block.Migration.t()]
  def migrations(resource_or_dsl) do
    case definition(resource_or_dsl) do
      %{migrations: migrations} -> migrations
      _ -> []
    end
  end
end
