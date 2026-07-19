defmodule KilnCMS.Blocks.Claim do
  @moduledoc """
  A sourced factual claim (#357, GEO — citation metadata).

  Marks one statement with the source that backs it, so answer engines can
  cite accurately. The citation rides on **every** fired surface: the `:web`
  HTML carries a `<cite>` link, the `:llm` Markdown appends a `Source:` line
  to the passage, and the `:json_ld` render contributes a schema.org
  **`Claim`** node (with `citation`) — or a **`ClaimReview`** node when a
  fact-check `rating` is set (e.g. "True", "Misleading").

  This is the per-claim counterpart of document provenance (#340): provenance
  says who edited the content; a claim block says where a statement came from.
  """
  use Kiln.Block

  block :claim do
    field :text, :string, required: true
    field :source_title, :string
    field :source_url, :url
    # Optional fact-check verdict; when set the block fires a ClaimReview node.
    field :rating, :string
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    cite =
      case {safe_url(block), title(block)} do
        {nil, nil} ->
          []

        {nil, title} ->
          [" <cite>", esc(title), "</cite>"]

        {url, title} ->
          [
            " <cite><a href=\"",
            esc(url),
            "\" rel=\"noopener\">",
            esc(title || url),
            "</a></cite>"
          ]
      end

    ["<p class=\"kiln-claim\">", esc(block.text || ""), cite, "</p>"]
  end

  def render(block, :json) do
    %{
      "_type" => "claim",
      "text" => block.text,
      "source_title" => block.source_title,
      "source_url" => block.source_url,
      "rating" => block.rating
    }
  end

  def render(block, :json_ld) do
    text = String.trim(block.text || "")

    cond do
      text == "" ->
        nil

      rating(block) ->
        %{
          "@type" => "ClaimReview",
          "claimReviewed" => text,
          "reviewRating" => %{"@type" => "Rating", "alternateName" => rating(block)}
        }
        |> put_if("itemReviewed", claim_node(text, block))

      true ->
        claim_node(text, block) || %{"@type" => "Claim", "text" => text}
    end
  end

  @impl Kiln.Block.Renderer
  def search_text(block),
    do: [block.text, block.source_title] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

  # The `:llm` surface: the claim as a passage with an explicit `Source:` line,
  # so an extracting engine picks the citation up alongside the statement.
  def to_markdown(block) do
    text = String.trim(block.text || "")

    source =
      case {safe_url(block), title(block)} do
        {nil, nil} -> nil
        {nil, title} -> "Source: #{title}"
        {url, nil} -> "Source: <#{url}>"
        {url, title} -> "Source: [#{title}](#{url})"
      end

    [text, source] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")
  end

  # A `Claim` node with its citation; nil when there is no citation at all
  # (callers fall back to a bare Claim / omit itemReviewed).
  defp claim_node(text, block) do
    citation =
      %{"@type" => "CreativeWork"}
      |> put_if("name", title(block))
      |> put_if("url", safe_url(block))

    if map_size(citation) > 1 do
      %{"@type" => "Claim", "text" => text, "citation" => citation}
    end
  end

  defp title(block) do
    case block.source_title do
      title when is_binary(title) and title != "" -> title
      _ -> nil
    end
  end

  defp rating(block) do
    case block.rating do
      rating when is_binary(rating) and rating != "" -> rating
      _ -> nil
    end
  end

  # Reject non-http(s) schemes so fired surfaces never carry e.g. `javascript:`.
  defp safe_url(block), do: KilnCMS.HTMLSanitizer.safe_href(block.source_url)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
