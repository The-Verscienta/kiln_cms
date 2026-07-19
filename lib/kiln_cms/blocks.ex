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
    rich_text: KilnCMS.Blocks.RichText,
    quote: KilnCMS.Blocks.Quote,
    embed: KilnCMS.Blocks.Embed,
    divider: KilnCMS.Blocks.Divider,
    form: KilnCMS.Blocks.Form,
    columns: KilnCMS.Blocks.Columns,
    # GEO blocks (#357): structured Q&A, procedures, and sourced claims whose
    # :json_ld renders expand the fired @graph (FAQPage / HowTo / Claim(Review)).
    faq: KilnCMS.Blocks.Faq,
    how_to: KilnCMS.Blocks.HowTo,
    claim: KilnCMS.Blocks.Claim,
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

  @doc "All block modules using `Kiln.Block` — the app's own plus plugin-contributed."
  @spec modules() :: [module()]
  def modules do
    app_modules =
      case :application.get_key(:kiln_cms, :modules) do
        {:ok, mods} -> Enum.filter(mods, &kiln_block?/1)
        _ -> []
      end

    # Plugin blocks may live in another OTP app (hex-dep plugins), which the
    # app-modules scan can't see.
    Enum.uniq(app_modules ++ Kiln.Plugins.blocks())
  end

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

  defp kiln_block?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :render, 2) and
      Kiln.Block.Renderer in behaviours(module)
  end

  # A module can declare several `@behaviour`s; module_info/1 returns one
  # `:behaviour` entry per declaration, so collect them all (not just the first).
  defp behaviours(module) do
    for {:behaviour, list} <- module.module_info(:attributes), behaviour <- list, do: behaviour
  end
end
