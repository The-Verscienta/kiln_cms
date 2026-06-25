defmodule Kiln.Block.Field do
  @moduledoc "Target struct for a `field` DSL entry (Kiln v2 — D10)."
  # __spark_metadata__ is required by Spark for source annotations.
  defstruct [:name, :type, :required, :default, :description, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule Kiln.Block.Definition do
  @moduledoc "Target struct for the `block` DSL entry (Kiln v2 — D10)."
  defstruct [:name, :version, :__spark_metadata__, fields: []]
  @type t :: %__MODULE__{}
end

defmodule Kiln.Block.Dsl do
  @moduledoc """
  Spark DSL extension that turns one declarative block definition into a full
  typed embedded block (Kiln v2 — decision D10).

      defmodule KilnCMS.Blocks.Hero do
        use Kiln.Block

        block :hero do
          field :headline, :string, required: true
          field :subheadline, :rich_text
        end
      end

  `block`/`field` are added as a **top-level** section on `Ash.Resource`, and
  `Kiln.Block.Transformer` maps each `field` to an Ash embedded attribute. The
  block `name` doubles as the `_type` discriminator the Phase C `Ash.Type.Union`
  keys on (decision D11); `version` feeds Phase H upcasting (decision D15).
  """

  @field %Spark.Dsl.Entity{
    name: :field,
    describe: "A typed field on the block. Maps to an Ash embedded attribute.",
    args: [:name, :type],
    target: Kiln.Block.Field,
    schema: [
      name: [type: :atom, required: true, doc: "Field name (becomes an attribute)."],
      type: [
        type: :any,
        required: true,
        doc:
          "Kiln field type: :string | :integer | :boolean | :date | :datetime | " <>
            ":slug | :url | :email | :color | :rich_text | :image | :reference | " <>
            ":map | :object | {:array, t}."
      ],
      required: [type: :boolean, default: false, doc: "Sets allow_nil? false."],
      default: [type: :any, required: false, doc: "Attribute default."],
      description: [type: :string, required: false, doc: "Attribute docs."]
    ]
  }

  @block %Spark.Dsl.Entity{
    name: :block,
    describe: "Defines the block type and its fields.",
    args: [:name],
    target: Kiln.Block.Definition,
    entities: [fields: [@field]],
    schema: [
      name: [type: :atom, required: true, doc: "Block name / `_type` discriminator."],
      version: [type: :pos_integer, default: 1, doc: "Schema version (Phase H upcasting)."]
    ]
  }

  @section %Spark.Dsl.Section{
    name: :kiln_block,
    describe: "Declares the block type for a module using `Kiln.Block`.",
    top_level?: true,
    entities: [@block]
  }

  use Spark.Dsl.Extension, sections: [@section], transformers: [Kiln.Block.Transformer]
end
