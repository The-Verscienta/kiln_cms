defmodule Kiln.Block.Transformer do
  @moduledoc """
  Translates `Kiln.Block` `field` entries into Ash embedded attributes at compile
  time (Kiln v2 — decision D10). Runs before Ash's `DefaultAccept` so the fields
  are part of the embedded resource's accepted params.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Ensure default_accept picks up the attributes we add.
  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    case Transformer.get_entities(dsl_state, [:kiln_block]) do
      [%Kiln.Block.Definition{name: name, fields: fields}] ->
        dsl_state =
          dsl_state
          |> add_discriminator(name)
          |> then(&Enum.reduce(fields, &1, fn field, acc -> add_field(field, acc) end))

        {:ok, dsl_state}

      [] ->
        {:error, "Kiln.Block: define exactly one `block` per module (found none)."}

      many ->
        {:error, "Kiln.Block: define exactly one `block` per module (found #{length(many)})."}
    end
  end

  # The `_type` discriminator the Phase C `Ash.Type.Union` tags on (decision D11).
  # Defaults to the block name, so directly-built structs are already tagged.
  defp add_discriminator(dsl_state, name) do
    {:ok, dsl_state} =
      Ash.Resource.Builder.add_attribute(dsl_state, :_type, :string,
        default: to_string(name),
        allow_nil?: false,
        public?: true
      )

    dsl_state
  end

  defp add_field(%Kiln.Block.Field{} = field, dsl_state) do
    opts =
      [allow_nil?: !field.required, public?: true]
      |> maybe_put(:default, field.default)
      |> maybe_put(:description, field.description)

    {:ok, dsl_state} =
      Ash.Resource.Builder.add_attribute(dsl_state, field.name, ash_type(field.type), opts)

    dsl_state
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Kiln field type → Ash type. Nested typed objects and first-class media/
  # reference types are deliberately stubbed to map/string here; they get proper
  # treatment in later phases (object → embedded in a future phase, image →
  # Phase J media, reference → Phase E graph).
  defp ash_type(:string), do: :string
  defp ash_type(:integer), do: :integer
  defp ash_type(:boolean), do: :boolean
  defp ash_type(:date), do: :date
  defp ash_type(:datetime), do: :utc_datetime
  defp ash_type(:slug), do: :string
  defp ash_type(:url), do: :string
  defp ash_type(:email), do: :string
  defp ash_type(:color), do: :string
  # Portable Text is canonical (decision D12): a list of PT JSON block maps.
  defp ash_type(:rich_text), do: {:array, :map}
  defp ash_type(:image), do: :string
  defp ash_type(:reference), do: :map
  defp ash_type(:object), do: :map
  defp ash_type(:map), do: :map
  defp ash_type({:array, inner}), do: {:array, ash_type(inner)}
  defp ash_type(other), do: other
end
