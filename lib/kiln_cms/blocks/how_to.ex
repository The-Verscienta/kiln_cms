defmodule KilnCMS.Blocks.HowTo do
  @moduledoc """
  A step-by-step instructions block (#357, GEO).

  Its `:json_ld` render contributes a schema.org **`HowTo`** node (ordered
  `HowToStep`s) to the fired `@graph`, so answer engines can lift the procedure
  with its step structure intact. Steps are stored as raw string-keyed maps
  (jsonb), like the `faq` block's items:

      %{"_type" => "how_to", "name" => "Brew tea", "steps" => [
        %{"name" => "Boil", "text" => "Bring water to 95 °C."}
      ]}
  """
  use Kiln.Block

  block :how_to do
    # The task being explained (schema.org `HowTo.name`).
    field :name, :string
    field :description, :string
    # Each entry: `%{"name" => label, "text" => instruction}` (string keys).
    field :steps, {:array, :map}, default: []
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    heading =
      case block.name do
        nil -> []
        "" -> []
        name -> ["<h2>", esc(name), "</h2>"]
      end

    description =
      case block.description do
        nil -> []
        "" -> []
        description -> ["<p>", esc(description), "</p>"]
      end

    entries =
      for {label, text} <- pairs(block) do
        label_html = if label == "", do: [], else: ["<strong>", esc(label), "</strong> "]
        ["<li>", label_html, esc(text), "</li>"]
      end

    ["<section class=\"kiln-howto\">", heading, description, "<ol>", entries, "</ol></section>"]
  end

  def render(block, :json) do
    %{
      "_type" => "how_to",
      "name" => block.name,
      "description" => block.description,
      "steps" => steps(block)
    }
  end

  def render(block, :json_ld) do
    case pairs(block) do
      [] ->
        nil

      pairs ->
        steps =
          pairs
          |> Enum.with_index(1)
          |> Enum.map(fn {{label, text}, position} ->
            %{"@type" => "HowToStep", "position" => position, "text" => text}
            |> put_if("name", label)
          end)

        %{"@type" => "HowTo", "step" => steps}
        |> put_if("name", block.name)
        |> put_if("description", block.description)
    end
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    steps =
      block
      |> pairs()
      |> Enum.map_join(" ", fn {label, text} -> String.trim("#{label} #{text}") end)

    String.trim("#{block.name || ""} #{block.description || ""} #{steps}")
  end

  # The `:llm` surface: heading + numbered steps — an extractable procedure.
  def to_markdown(block) do
    heading =
      case block.name do
        nil -> []
        "" -> []
        name -> ["## " <> name]
      end

    description =
      case block.description do
        nil -> []
        "" -> []
        description -> [description]
      end

    steps =
      case pairs(block) do
        [] ->
          []

        pairs ->
          [
            pairs
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn
              {{"", text}, n} -> "#{n}. #{text}"
              {{label, text}, n} -> "#{n}. **#{label}** — #{text}"
            end)
          ]
      end

    Enum.join(heading ++ description ++ steps, "\n\n")
  end

  @doc "Normalized steps: string-keyed maps with `name`/`text` strings."
  @spec steps(struct()) :: [%{String.t() => String.t()}]
  def steps(block) do
    block.steps
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn step ->
      %{"name" => field_str(step, "name", :name), "text" => field_str(step, "text", :text)}
    end)
  end

  # Steps with a non-blank instruction, as `{label, text}` tuples.
  defp pairs(block) do
    for %{"name" => label, "text" => text} <- steps(block), text != "", do: {label, text}
  end

  # Tolerates string keys (jsonb/form params) and atom keys (seeds/tests).
  defp field_str(step, key, atom_key) do
    case Map.get(step, key) || Map.get(step, atom_key) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
