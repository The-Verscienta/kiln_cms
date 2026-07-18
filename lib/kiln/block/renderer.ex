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
end
