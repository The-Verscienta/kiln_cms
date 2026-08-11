defmodule KilnCMS.Blocks.Accordion do
  @moduledoc """
  Collapsible title/content panels, with **no structured data** (#482).

  The semantically neutral sibling of `KilnCMS.Blocks.Faq`. Both render
  `<details>/<summary>`, and that shared appearance is exactly the problem this
  block exists to solve: `faq` always emits a schema.org `FAQPage` node into the
  fired `@graph`, so an editor reaching for "a thing that collapses" — a
  specification table, a changelog, a set of terms — was publishing a claim that
  the page is a list of questions and answers. Answer engines act on that claim.

  So the split is by *meaning*, not by looks:

    * `faq` — genuine questions and answers. Emits `FAQPage`. That is the point
      of it (#357, GEO).
    * `accordion` — anything else that folds. Emits **nothing**;
      `render/2` returns `nil` for `:json_ld` deliberately, and the test that
      asserts it is the whole contract.

  Panels are stored as raw string-keyed maps (jsonb), mirroring `faq`'s items
  and the `columns` block's children: a plain map array keeps the storage union
  flat and the editor round-trip trivial.

      %{"_type" => "accordion", "title" => "Specifications", "panels" => [
        %{"title" => "Dimensions", "content" => "…"}
      ]}

  Panel content is plain text, not prose. A panel that needs formatting is a
  `columns` block away from having it, and admitting rich text here would mean a
  second sanitizer boundary for a block whose whole purpose is to be the *plain*
  one.
  """
  use Kiln.Block

  block :accordion do
    # Optional section heading rendered above the panels.
    field :title, :string
    # Each entry: `%{"title" => t, "content" => c}` (string keys, as stored).
    field :panels, {:array, :map}, default: [], translatable: [:title, :content]
    # Whether the first panel renders expanded. Editors kept asking; the
    # alternative is a page that opens looking empty.
    field :first_open, :boolean, default: false
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    entries =
      block
      |> pairs()
      |> Enum.with_index()
      |> Enum.map(fn {{t, c}, index} ->
        open = if index == 0 and block.first_open, do: " open", else: ""

        [
          "<details class=\"kiln-accordion-item\"",
          open,
          "><summary>",
          esc(t),
          "</summary><div class=\"kiln-accordion-body\"><p>",
          esc(c),
          "</p></div></details>"
        ]
      end)

    title =
      case block.title do
        nil -> []
        "" -> []
        title -> ["<h2>", esc(title), "</h2>"]
      end

    ["<section class=\"kiln-accordion\">", title, entries, "</section>"]
  end

  def render(block, :json),
    do: %{
      "_type" => "accordion",
      "title" => block.title,
      "first_open" => block.first_open == true,
      "panels" => panels(block)
    }

  # Deliberately nothing. See the moduledoc: emitting FAQPage here is the bug
  # this block was added to stop, and there is no schema.org type for "content
  # that happens to be collapsed" — presentation is not structured data.
  def render(_block, :json_ld), do: nil

  # `panels/1` normalizes every entry, so the delivered array is never null and
  # both keys are always present strings. `first_open` is coerced to a real
  # boolean on render.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "properties" => %{
        "panels" => Kiln.Block.JsonSchema.object_array(~w(title content)),
        "first_open" => %{"type" => "boolean", "default" => false}
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    text = block |> pairs() |> Enum.map_join(" ", fn {t, c} -> String.trim("#{t} #{c}") end)
    String.trim("#{block.title || ""} #{text}")
  end

  # The `:llm` surface. Headings rather than `faq`'s `###` Q-shape, because these
  # are sections, not questions — an answer engine chunking this should see a
  # document outline, not a Q&A pair it can lift as a snippet.
  def to_markdown(block) do
    title =
      case block.title do
        nil -> []
        "" -> []
        title -> ["## " <> title]
      end

    entries = for {t, c} <- pairs(block), do: "### #{t}\n\n#{c}"
    Enum.join(title ++ entries, "\n\n")
  end

  @doc "Normalized panels: string-keyed maps with `title`/`content` strings."
  @spec panels(struct()) :: [%{String.t() => String.t()}]
  def panels(block) do
    block.panels
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn panel ->
      %{
        "title" => field_str(panel, "title", :title),
        "content" => field_str(panel, "content", :content)
      }
    end)
  end

  # Panels with a non-blank title, as `{title, content}` tuples. A panel with no
  # title has no summary to click, so it would render as an unopenable box.
  defp pairs(block) do
    for %{"title" => t, "content" => c} <- panels(block), t != "", do: {t, c}
  end

  # Tolerates string keys (jsonb/form params) and atom keys (seeds/tests).
  defp field_str(panel, key, atom_key) do
    case Map.get(panel, key) || Map.get(panel, atom_key) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
