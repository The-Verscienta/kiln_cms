defmodule Kiln.Block do
  @moduledoc """
  Base for a typed content block (Kiln v2 — decision D10).

  `use Kiln.Block` turns a module into an Ash **embedded** resource carrying the
  `Kiln.Block.Dsl` extension, a stable `:id`, the standard embedded actions, and
  overridable `Kiln.Block.Renderer` defaults. The module then declares its shape:

      defmodule KilnCMS.Blocks.Heading do
        use Kiln.Block

        block :heading do
          field :text, :string, required: true
          field :level, :integer, default: 2
        end

        def render(b, :web), do: ["<h", to_string(b.level), ">", ...]
        def search_text(b), do: b.text || ""
      end

  From that one definition you get the embedded schema + validation (via the
  transformer), the `_type` discriminator + version (via `Kiln.Block.Info`), and
  the serializers (the overridden render contract). Blocks are discovered and
  dispatched through `KilnCMS.Blocks`.

  Do **not** pattern-match `%__MODULE__{}` in your `render/2` or `search_text/1`
  heads. The block's struct is built by a transformer at `@before_compile` —
  after these heads compile — so referencing it (even the bare `%__MODULE__{}`)
  raises `__struct__/1 is undefined` on a clean compile. Match a plain variable
  and read fields in the body; `KilnCMS.Blocks` dispatches by struct type, so the
  argument is always this block.
  """

  defmacro __using__(_opts) do
    quote do
      use Ash.Resource,
        data_layer: :embedded,
        embed_nil_values?: false,
        extensions: [Kiln.Block.Dsl]

      @behaviour Kiln.Block.Renderer

      attributes do
        # Writable so block ids stay stable across version restores / round-trips
        # (mirrors the legacy KilnCMS.CMS.Block behaviour).
        uuid_primary_key :id, writable?: true
      end

      actions do
        defaults [:read, :create, :update, :destroy]
        # Fields are added dynamically by the transformer, so accept all public
        # attributes (Ash 3 defaults default_accept to []).
        default_accept :*
      end

      # Overridable, total defaults — a block only overrides what it renders.
      def render(_block, _surface), do: nil
      def search_text(_block), do: ""

      defoverridable render: 2, search_text: 1
    end
  end
end
