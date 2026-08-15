defmodule KilnCMS.Blocks do
  @moduledoc """
  Registry and serializer dispatch for typed blocks (Kiln v2 — D10/D11).

  Block modules (`use Kiln.Block`) are discovered from the compiled application,
  keyed by their `_type` discriminator. `render/2` and `search_text/1` dispatch by
  struct type — multiple dispatch *is* the serializer registry (decision A4). The
  registry is what the Phase C `Ash.Type.Union` and the Phase D firing service
  build on.
  """

  # The core block set. Plugins (D18) extend it via `Kiln.Plugin.blocks/0`;
  # `union_types/0` below is the single compile-time source the storage union
  # and the legacy bridge derive from.
  @core_blocks [
    heading: KilnCMS.Blocks.Heading,
    image: KilnCMS.Blocks.Image,
    # A downloadable document attachment (#481) — deliberately not named
    # "document" to avoid colliding with the unrelated "document" vocabulary
    # elsewhere in the CMS (content types, the DB "documents").
    file: KilnCMS.Blocks.File,
    # Self-hosted A/V (#494) — distinct from `embed`, which points at
    # YouTube/Vimeo. Two blocks rather than one with a kind flag: an
    # `<audio>` has no poster and no captions track, so half a shared block's
    # fields would be permanently inert on it.
    video: KilnCMS.Blocks.Video,
    audio: KilnCMS.Blocks.Audio,
    rich_text: KilnCMS.Blocks.RichText,
    quote: KilnCMS.Blocks.Quote,
    embed: KilnCMS.Blocks.Embed,
    divider: KilnCMS.Blocks.Divider,
    form: KilnCMS.Blocks.Form,
    columns: KilnCMS.Blocks.Columns,
    gallery: KilnCMS.Blocks.Gallery,
    # The semantically neutral sibling of `faq` (#482): same `<details>` markup,
    # deliberately no structured data. See its moduledoc for why that split is by
    # meaning rather than by looks.
    accordion: KilnCMS.Blocks.Accordion,
    # GEO blocks (#357): structured Q&A, procedures, and sourced claims whose
    # :json_ld renders expand the fired @graph (FAQPage / HowTo / Claim(Review)).
    faq: KilnCMS.Blocks.Faq,
    how_to: KilnCMS.Blocks.HowTo,
    claim: KilnCMS.Blocks.Claim,
    # Reusable content fragments (#479): a reference that is *inlined* before
    # any renderer runs (see `KilnCMS.CMS.Fragments`), so it has no surface
    # output of its own.
    fragment: KilnCMS.Blocks.Fragment,
    custom: KilnCMS.Blocks.Custom
  ]

  @doc """
  The `Ash.Type.Union` member spec for `KilnCMS.CMS.BlockUnion`: the core
  blocks plus every installed plugin's blocks, keyed by each module's
  `Kiln.Block` name. Evaluated at **compile time** (the union is a storage
  type), which is why the plugin list is `Application.compile_env`.
  """
  @spec union_types() :: keyword()
  def union_types do
    plugin = for mod <- Kiln.Plugins.blocks(), do: {Kiln.Block.Info.name(mod), mod}

    for {name, mod} <- @core_blocks ++ plugin do
      {name, [type: mod, tag: :_type, tag_value: to_string(name)]}
    end
  end

  @doc "The core block type names (excluding plugin contributions)."
  @spec core_types() :: [atom()]
  def core_types, do: Keyword.keys(@core_blocks)

  @doc "The core block modules (excluding plugin contributions)."
  @spec core_modules() :: [module()]
  def core_modules, do: Keyword.values(@core_blocks)

  @doc """
  All block modules using `Kiln.Block` — the core set plus every
  **registered** plugin's contributions (`Kiln.Plugins.blocks/0`, backed by
  `Application.compile_env(:kiln_cms, :plugins)`).

  Deliberately *not* a raw scan of every `Kiln.Block`-implementing module
  compiled into the app: `projects/` is always in `elixirc_paths` (every env,
  including a core-only build — see `projects/README.md`), so a downstream
  overlay's plugin can contribute a block that compiles into this very app
  while its owning plugin stays unregistered and dormant. A scan can't tell
  "compiled" from "active" — it would report that block here, feed it into
  the public schema export (`KilnCMS.SchemaExport`) and every nested-write
  validation that iterates this list, even on a build where the block is
  reachable nowhere in the actual `BlockUnion` storage type
  (`union_types/0`, built from this exact same core-plus-registered-plugins
  set). `mix kiln.plugins.doctor`'s own JSON-schema conformance check already
  avoids this trap the same way — see its `block_schema_problems/1`.
  """
  @spec modules() :: [module()]
  def modules, do: Enum.uniq(core_modules() ++ Kiln.Plugins.blocks())

  @doc "Map of `_type` discriminator → block module."
  @spec registry() :: %{atom() => module()}
  def registry, do: Map.new(modules(), &{Kiln.Block.Info.name(&1), &1})

  @doc "Look up a block module by its `_type`."
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(type) when is_atom(type), do: Map.fetch(registry(), type)

  @doc """
  Serialize a block struct to a surface (dispatches to the block module).

  For the `:json` delivery surface the block's stable `id` is injected as `_id`
  on the rendered map (blocks are Sanity-style `_type`-tagged maps that otherwise
  drop identity). This is the addressing anchor the visual-editing bridge (#355)
  maps a rendered value back to — the same id the in-context editor exposes as
  `data-kiln-block-id`. It recurses for free: container blocks (e.g. `columns`)
  render their children through this same function. Non-map renders (`nil`) and
  the `:web`/`:json_ld` surfaces are untouched.
  """
  @spec render(struct(), Kiln.Block.Renderer.surface()) :: iodata() | map() | nil
  def render(%module{} = block, :json) do
    case module.render(block, :json) do
      %{} = map -> maybe_put_id(map, Map.get(block, :id))
      other -> other
    end
  end

  def render(%module{} = block, surface), do: module.render(block, surface)

  defp maybe_put_id(map, nil), do: map
  defp maybe_put_id(map, id), do: Map.put(map, "_id", id)

  @doc "Plain-text projection of a block struct (dispatches to the block module)."
  @spec search_text(struct()) :: String.t()
  def search_text(%module{} = block), do: module.search_text(block)

  @doc """
  Markdown projection of a block for the `:llm` fired surface (#357). A block
  module opts into a richer rendering by exporting `to_markdown/1` (headings
  emit real `#` levels, containers recurse over their children through this
  dispatcher); everything else falls back to its plain-text projection.
  """
  @spec to_markdown(struct()) :: String.t() | nil
  def to_markdown(%module{} = block) do
    if function_exported?(module, :to_markdown, 1) do
      module.to_markdown(block)
    else
      search_text(block)
    end
  end
end
