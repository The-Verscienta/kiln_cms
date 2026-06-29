defmodule KilnCMS.Blocks.Embed do
  @moduledoc "An external media embed (Kiln v2 typed block — D10)."
  use Kiln.Block

  block :embed do
    # Not required — the embed URL is sanitized to a whitelisted host on save and
    # may be blanked, so an empty embed is a valid (no-op) placeholder.
    field :url, :string
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web),
    do: ["<figure class=\"kiln-embed\" data-url=\"", esc(block.url || ""), "\"></figure>"]

  def render(block, :json), do: %{"_type" => "embed", "url" => block.url}
  def render(_block, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(_block), do: ""

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
