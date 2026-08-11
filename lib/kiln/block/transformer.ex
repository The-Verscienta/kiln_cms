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
      [%Kiln.Block.Definition{name: name, version: version, fields: fields}] ->
        with :ok <- validate_translatable(fields),
             do: {:ok, build(dsl_state, name, version, fields)}

      [] ->
        {:error, "Kiln.Block: define exactly one `block` per module (found none)."}

      many ->
        {:error, "Kiln.Block: define exactly one `block` per module (found #{length(many)})."}
    end
  end

  defp build(dsl_state, name, version, fields) do
    dsl_state
    |> add_discriminator(name)
    |> add_version(version)
    |> then(&Enum.reduce(fields, &1, fn field, acc -> add_field(field, acc) end))
  end

  # `translatable:` has to agree with the field's type, checked here because the
  # failure it prevents is silent: `Kiln.Block.Info.translatable/1` matches on
  # shape, so a key list on a `:string` (or `true` on an `{:array, :map}`) falls
  # through the walker's catch-all and the field is absent from every export
  # *and* from the warnings — the exact outcome `:unsupported` exists to make
  # impossible. Spark's `{:or, …}` type-checks the value, not the pairing.
  defp validate_translatable(fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case {field.translatable, field.type} do
        {[_ | _], {:array, :map}} ->
          {:cont, :ok}

        {[_ | _], type} ->
          {:halt,
           {:error,
            "Kiln.Block: field #{inspect(field.name)} declares translatable keys, which only " <>
              "an {:array, :map} field has (got #{inspect(type)})."}}

        {true, type} when type not in [:string, :rich_text] ->
          {:halt,
           {:error,
            "Kiln.Block: field #{inspect(field.name)} is marked translatable, but " <>
              "#{inspect(type)} carries no prose. Name the keys to translate if it is an " <>
              "{:array, :map}, or drop the option."}}

        _ok ->
          {:cont, :ok}
      end
    end)
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

  # The stored schema version (decision D15). Defaults to the block's current
  # version so freshly-built structs are already at head; older stored maps carry
  # a lower `_version` and get upcast on read (`KilnCMS.Blocks.Upcaster`).
  defp add_version(dsl_state, version) do
    {:ok, dsl_state} =
      Ash.Resource.Builder.add_attribute(dsl_state, :_version, :integer,
        default: version,
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
