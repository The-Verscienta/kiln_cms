defmodule Kiln.Block.Renderer do
  @moduledoc """
  The render contract every typed block implements (Kiln v2 — decision D10).

  One block module = one embedded resource = one set of serializers. Dispatch is
  multiple-dispatch by struct type (see `KilnCMS.Blocks.render/2`): the registry
  *is* the serializer registry. Implementations must be **total** — an unhandled
  surface returns `nil` (no contribution) rather than raising, which is what makes
  the Phase J serializer property tests achievable (decision A4).

  `use Kiln.Block` injects overridable defaults for both callbacks, so a block
  only overrides what it actually renders.
  """

  @typedoc "A v1 firing surface (decision A2)."
  @type surface :: :web | :json | :json_ld

  @doc """
  Serialize a block to a surface. Web → iodata; json → map (or nil); json_ld → a
  schema.org node map, `nil`, or a list of nodes (a container block flattens its
  children's nodes — the firing engine flat-maps the results into the @graph).
  """
  @callback render(block :: struct(), surface()) :: iodata() | map() | [map()] | nil

  @doc "Plain text projection used for search/embeddings (decision D16)."
  @callback search_text(block :: struct()) :: String.t()

  @doc """
  A **patch** onto the block's derived `:json` JSON Schema (#430).

  `Kiln.Block.JsonSchema` derives a block's delivery schema from its `field`
  declarations, which is exact for most blocks. It is *not* exact for the ones
  whose `render/2` `:json` clause projects rather than mirrors — an `image`
  drops `media_id`, a `video` resolves `media_id`/`url` into one `src`, a
  `file` adds a computed `download_url`. Those blocks implement this callback
  so the exported schema describes what delivery actually serves.

  It is also where a block with a `{:array, :map}` field says what those maps
  hold: the derived schema can only say "array of object", while `gallery`,
  `faq` and friends know their item shape exactly.

  Three keys, all optional:

    * `"properties"` — merged **into** the derived properties (adds or replaces
      one at a time; untouched fields keep their derived schema);
    * `"drop"` — property names to remove, for fields the `:json` render does
      not project;
    * `"required"` — replaces the derived required list wholesale.

  Any other key is merged onto the block's schema object as-is. `"drop"` is a
  Kiln directive consumed by the exporter and never appears in the output.

  Optional: a block whose `:json` render mirrors its fields needs nothing here.
  """
  @callback json_schema() :: map()

  @optional_callbacks json_schema: 0
end
