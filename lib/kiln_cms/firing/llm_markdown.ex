defmodule KilnCMS.Firing.LlmMarkdown do
  @moduledoc """
  The `:llm` fired surface (#357, GEO phase 2): a clean, chunked **Markdown**
  rendering of a document, produced at publish time alongside `:web` /
  `:json` / `:json_ld`.

  Answer engines and LLM crawlers extract Markdown far more reliably than
  themed HTML — this is the per-document counterpart of `/llms.txt` (the
  llmstxt.org index), which links each entry's `.md` form here.

  Composition per block: a block module may export an optional
  `to_markdown/1` for a richer rendering; headings become real `#`-prefixed
  Markdown headings; every other block contributes its `search_text/1`
  projection as a paragraph. Blocks are separated by blank lines, so each
  becomes a naturally chunkable passage.
  """

  alias KilnCMS.Blocks

  @doc "Render `document` (+ its typed blocks) to one Markdown string."
  @spec compose(struct(), [struct()]) :: String.t()
  def compose(document, typed) do
    title = ["# " <> to_string(Map.get(document, :title) || "")]

    excerpt =
      case Map.get(document, :excerpt) do
        e when is_binary(e) and e != "" -> ["> " <> e]
        _ -> []
      end

    blocks =
      typed
      |> Enum.map(&block_markdown/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(title ++ excerpt ++ blocks, "\n\n") <> "\n"
  end

  # Per-block Markdown. The head matches a plain var, never `%__MODULE__{}` —
  # block structs are built late by Ash (clean-compile gotcha).
  defp block_markdown(block) do
    module = block.__struct__

    cond do
      function_exported?(module, :to_markdown, 1) ->
        module.to_markdown(block)

      module == KilnCMS.Blocks.Heading ->
        level = if block.level in 1..6, do: block.level, else: 2
        String.duplicate("#", level) <> " " <> Blocks.search_text(block)

      true ->
        Blocks.search_text(block)
    end
  end
end
