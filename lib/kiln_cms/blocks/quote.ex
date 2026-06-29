defmodule KilnCMS.Blocks.Quote do
  @moduledoc "A pull quote (Kiln v2 typed block — D10)."
  use Kiln.Block

  block :quote do
    field :text, :string, required: true
    field :citation, :string
    # Field-level policy (Phase J): editors may edit the quote, but only admins
    # may toggle whether it is featured.
    field :featured, :boolean, default: false, editable_by: [:admin]
  end

  @impl Kiln.Block.Renderer
  def render(%__MODULE__{} = block, :web) do
    cite =
      case block.citation do
        nil -> []
        "" -> []
        citation -> ["<cite>", esc(citation), "</cite>"]
      end

    ["<blockquote>", esc(block.text || ""), cite, "</blockquote>"]
  end

  def render(%__MODULE__{} = block, :json),
    do: %{"_type" => "quote", "text" => block.text, "citation" => block.citation}

  def render(%__MODULE__{}, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{} = block),
    do: [block.text, block.citation] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
