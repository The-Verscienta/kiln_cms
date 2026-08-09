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

defmodule KilnCMS.FixturePlugin.FieldTypes.Rating do
  @moduledoc """
  A plugin-contributed custom field type (test fixture, D18): a 1–5 star
  rating. Exercises the field-type registry end to end — the fields admin
  offers it, `ApplyCustomFields` dispatches writes to `cast/2`, and the
  content editor renders a number input with the declared min/max.
  """
  use Kiln.FieldType

  @impl Kiln.FieldType
  def cast(value, _definition) do
    case value do
      n when is_integer(n) and n in 1..5 -> {:ok, n}
      other -> parse(other)
    end
  end

  defp parse(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..5 -> {:ok, n}
      _ -> {:error, "must be a rating from 1 to 5"}
    end
  end

  @impl Kiln.FieldType
  def input_type, do: "number"

  @impl Kiln.FieldType
  def input_attrs(_definition), do: %{min: 1, max: 5}

  @doc """
  A word form of the rating, for slug/alias patterns (#804).

  The generic `[field:<name>]` token already gives `3`. This is the thing the
  generic path cannot produce — a value derived from the stored one — and it is
  scoped to *this field's* name, so two rating fields on one type each get their
  own token rather than fighting over a shared one.
  """
  @impl Kiln.FieldType
  def tokens(definition) do
    [
      %{
        match: ~r/\Afield:#{Regex.escape(definition.name)}\.word\z/,
        resolve: fn _token, context ->
          context
          |> Map.get(:custom_fields, %{})
          |> Kernel.||(%{})
          |> Map.get(definition.name)
          |> word()
        end
      }
    ]
  end

  @words %{1 => "one", 2 => "two", 3 => "three", 4 => "four", 5 => "five"}

  defp word(value) when is_integer(value), do: Map.get(@words, value, "")

  defp word(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> word(n)
      _other -> ""
    end
  end

  defp word(_value), do: ""
end

defmodule KilnCMS.FixturePlugin.FieldTypes.Tokenless do
  @moduledoc """
  A plugin field type that implements the behaviour but NOT the optional
  `c:Kiln.FieldType.tokens/1` (test fixture).

  Exists so `KilnCMS.CMS.Slugs.type_token_definitions/1`'s
  `Code.ensure_loaded?/1 and function_exported?/3` probe has a case that
  actually reaches it. A CORE field type cannot: `FieldTypes.get/1` returns
  `nil` for those, so a `:text` field exercises the nil clause and never the
  probe — which is why the branch shipped uncovered.
  """
  use Kiln.FieldType

  @impl Kiln.FieldType
  def cast(value, _definition), do: {:ok, to_string(value)}
end

defmodule KilnCMS.FixturePlugin.FieldTypes.Exploding do
  @moduledoc """
  A plugin field type whose `c:Kiln.FieldType.tokens/1` raises (test fixture).

  A third party's token list must never be able to fail the save it was merely
  decorating, so `type_token_definitions/1` rescues. This is the case that
  proves the rescue is still there.
  """
  use Kiln.FieldType

  @impl Kiln.FieldType
  def cast(value, _definition), do: {:ok, to_string(value)}

  @impl Kiln.FieldType
  def tokens(_definition), do: raise("plugin token list blew up")
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
  def version, do: "1.2.3"

  @impl true
  def summary, do: "Test fixture exercising every plugin seam."

  @impl true
  def homepage, do: "https://example.com/fixture-plugin"

  @impl true
  def blocks, do: [KilnCMS.FixturePlugin.CalloutBlock]

  @impl true
  def field_types,
    do: [
      KilnCMS.FixturePlugin.FieldTypes.Rating,
      KilnCMS.FixturePlugin.FieldTypes.Tokenless,
      KilnCMS.FixturePlugin.FieldTypes.Exploding
    ]

  @impl true
  def nav_items, do: [%{label: "Fixture", path: "/editor/fixture", role: :admin}]

  @impl true
  def admin_routes, do: [{"/editor/fixture", KilnCMS.FixturePlugin.PanelLive, :index}]

  @impl true
  def children, do: [KilnCMS.FixturePlugin.Counter]

  @impl true
  def oban_queues, do: [fixture: 1]
end
