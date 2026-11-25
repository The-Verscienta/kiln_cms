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

  After the blocks come the custom fields an admin opted in
  (`FieldDefinition.deliver_llm`, #2282): one `##` section per field, from
  `KilnCMS.Firing.AnswerText`. With none opted in the output is what it was
  before.
  """

  alias KilnCMS.Blocks
  alias KilnCMS.Firing.AnswerText

  @doc """
  Render `document` (+ its typed blocks) to one Markdown string. `custom` is
  the resolved `KilnCMS.Firing.CustomFields` result, whose opted-in text
  closes the document.
  """
  @spec compose(struct(), [struct()], map() | nil) :: String.t()
  def compose(document, typed, custom \\ nil) do
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

    fields = custom |> AnswerText.entries() |> AnswerText.markdown()

    Enum.join(title ++ excerpt ++ blocks ++ fields, "\n\n") <> "\n"
  end

  # Per-block Markdown — the shared dispatcher owns the seam: block modules
  # export `to_markdown/1` (Heading, Columns) or fall back to search_text.
  defp block_markdown(block), do: Blocks.to_markdown(block)
end
