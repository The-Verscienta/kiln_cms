defmodule KilnPluginCallout.Blocks.Callout do
  @moduledoc """
  A "callout" block — a titled, variant-styled aside (info/warning/success).
  Defined in a third-party package, it behaves like any built-in KilnCMS block:
  it's a `Kiln.Block` (an Ash embedded resource) with a render contract.
  """
  use Kiln.Block

  block :callout do
    field :title, :string
    field :body, :string, required: true
    # info | warning | success — styles the aside.
    field :variant, :string, default: "info"
  end

  @impl Kiln.Block.Renderer
  def render(%__MODULE__{} = b, :web) do
    [
      ~s(<aside class="callout callout-),
      b.variant || "info",
      ~s(">),
      if(b.title, do: ["<strong>", b.title, "</strong>"], else: []),
      "<p>",
      b.body || "",
      "</p></aside>"
    ]
  end

  def render(%__MODULE__{} = b, _surface), do: b.body || ""

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{title: title, body: body}) do
    [title, body] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end
end
