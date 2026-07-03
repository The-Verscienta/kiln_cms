defmodule KilnCMS.FixturePlugin.CalloutBlock do
  @moduledoc """
  A plugin-contributed block type (test fixture, D18): exercises the whole
  block pipeline — storage union membership, editor palette, firing render,
  search projection — without a single core edit.
  """
  use Kiln.Block

  block :callout do
    field :text, :string, required: true
    field :tone, :string, default: "info"
  end

  # Plain-var heads (never `%__MODULE__{}` — the struct is built at
  # @before_compile, so matching it breaks clean compiles).
  @impl Kiln.Block.Renderer
  def render(block, :web),
    do: [
      ~s(<aside class="callout callout-),
      esc(block.tone || "info"),
      ~s(">),
      esc(block.text || ""),
      "</aside>"
    ]

  def render(block, :json),
    do: %{"_type" => "callout", "text" => block.text, "tone" => block.tone}

  def render(_block, _surface), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block), do: block.text || ""

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end

defmodule KilnCMS.FixturePlugin.PanelLive do
  @moduledoc "A plugin admin panel (test fixture) mounted via `admin_routes/0`."
  use KilnCMSWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fixture-panel">
      <h1>Fixture plugin panel</h1>
    </div>
    """
  end
end

defmodule KilnCMS.FixturePlugin.Counter do
  @moduledoc "A plugin supervision child (test fixture)."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
end

defmodule KilnCMS.FixturePlugin do
  @moduledoc """
  The test-suite plugin (D18): registered in `config/test.exs`, it exercises
  every plugin seam end to end — see `test/kiln/plugins_test.exs`.
  """
  use Kiln.Plugin

  @impl true
  def blocks, do: [KilnCMS.FixturePlugin.CalloutBlock]

  @impl true
  def nav_items, do: [%{label: "Fixture", path: "/editor/fixture", role: :admin}]

  @impl true
  def admin_routes, do: [{"/editor/fixture", KilnCMS.FixturePlugin.PanelLive, :index}]

  @impl true
  def children, do: [KilnCMS.FixturePlugin.Counter]

  @impl true
  def oban_queues, do: [fixture: 1]
end
