defmodule Example.Blocks.Stat do
  @moduledoc """
  A plugin-contributed block type (D18): a highlighted number/label pair,
  e.g. "10,000+ / customers served". Exercises the whole block pipeline —
  storage union membership, editor palette, firing render, search
  projection — from a downstream overlay's plugin, without a single core
  edit. See `KilnCMS.FixturePlugin.CalloutBlock` (`test/support/`) for the
  core-side test fixture this mirrors; `KilnCMS.Blocks.Divider`
  (`lib/kiln_cms/blocks/divider.ex`) for the field-less minimal shape.
  """
  use Kiln.Block

  block :stat do
    field :value, :string, required: true
    field :label, :string, required: true
  end

  # Plain-var heads, not `%__MODULE__{}` — the struct is built by an Ash
  # transformer at @before_compile, so it isn't available when these heads
  # compile.
  @impl Kiln.Block.Renderer
  def render(block, :web),
    do: [
      ~s(<div class="stat"><span class="stat-value">),
      esc(block.value || ""),
      ~s(</span><span class="stat-label">),
      esc(block.label || ""),
      "</span></div>"
    ]

  def render(block, :json),
    do: %{"_type" => "stat", "value" => block.value, "label" => block.label}

  def render(_block, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block),
    do: [block.value, block.label] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
