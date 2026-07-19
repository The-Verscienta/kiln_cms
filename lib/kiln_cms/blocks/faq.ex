defmodule KilnCMS.Blocks.Faq do
  @moduledoc """
  A question-and-answer list block (#357, GEO).

  Its `:json_ld` render contributes a schema.org **`FAQPage`** node
  (`Question` / `acceptedAnswer` pairs) to the fired `@graph` — the markup
  answer engines lift Q&A snippets from. Items are stored as raw string-keyed
  maps (jsonb), mirroring the `columns` block's children: a plain map array
  keeps the storage union flat and the editor round-trip trivial.

      %{"_type" => "faq", "title" => "FAQ", "items" => [
        %{"question" => "…?", "answer" => "…"}
      ]}
  """
  use Kiln.Block

  block :faq do
    # Optional section heading rendered above the list.
    field :title, :string
    # Each entry: `%{"question" => q, "answer" => a}` (string keys, as stored).
    field :items, {:array, :map}, default: []
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    entries =
      for {q, a} <- pairs(block) do
        [
          "<details class=\"kiln-faq-item\"><summary>",
          esc(q),
          "</summary><p>",
          esc(a),
          "</p></details>"
        ]
      end

    title =
      case block.title do
        nil -> []
        "" -> []
        title -> ["<h2>", esc(title), "</h2>"]
      end

    ["<section class=\"kiln-faq\">", title, entries, "</section>"]
  end

  def render(block, :json),
    do: %{"_type" => "faq", "title" => block.title, "items" => items(block)}

  # One FAQPage node per block; blank questions contribute nothing.
  def render(block, :json_ld) do
    case pairs(block) do
      [] ->
        nil

      pairs ->
        %{
          "@type" => "FAQPage",
          "mainEntity" =>
            Enum.map(pairs, fn {q, a} ->
              %{
                "@type" => "Question",
                "name" => q,
                "acceptedAnswer" => %{"@type" => "Answer", "text" => a}
              }
            end)
        }
    end
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    text = block |> pairs() |> Enum.map_join(" ", fn {q, a} -> String.trim("#{q} #{a}") end)
    String.trim("#{block.title || ""} #{text}")
  end

  # The `:llm` surface: each Q becomes a `###` heading with its answer as the
  # following passage — the naturally chunkable shape answer engines extract.
  def to_markdown(block) do
    title =
      case block.title do
        nil -> []
        "" -> []
        title -> ["## " <> title]
      end

    entries = for {q, a} <- pairs(block), do: "### #{q}\n\n#{a}"
    Enum.join(title ++ entries, "\n\n")
  end

  @doc "Normalized items: string-keyed maps with `question`/`answer` strings."
  @spec items(struct()) :: [%{String.t() => String.t()}]
  def items(block) do
    block.items
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      %{
        "question" => field_str(item, "question", :question),
        "answer" => field_str(item, "answer", :answer)
      }
    end)
  end

  # Items with a non-blank question, as `{question, answer}` tuples.
  defp pairs(block) do
    for %{"question" => q, "answer" => a} <- items(block), q != "", do: {q, a}
  end

  # Tolerates string keys (jsonb/form params) and atom keys (seeds/tests).
  defp field_str(item, key, atom_key) do
    case Map.get(item, key) || Map.get(item, atom_key) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
