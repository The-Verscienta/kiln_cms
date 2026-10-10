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

defmodule KilnCMS.FixturePlugin.RestrictedRequiredBlock do
  @moduledoc """
  A plugin-contributed block type (test fixture): combines `required: true`
  with `editable_by:` on the same field — a combination no CORE block
  currently uses (code-review finding #7 on PR #1250, following #935).
  `KilnCMS.CMS.ContentCopyTest` exercises the duplicate/translate path this is
  for; nothing else in the suite should notice this block exists.
  """
  use Kiln.Block

  block :restricted_required do
    field :locked_text, :string, required: true, editable_by: [:admin]
  end

  @impl Kiln.Block.Renderer
  def render(block, :json),
    do: %{"_type" => "restricted_required", "locked_text" => block.locked_text}

  def render(_block, _surface), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block), do: block.locked_text || ""
end

defmodule KilnCMS.FixturePlugin.RestrictedRequiredDefaultBlock do
  @moduledoc """
  A plugin-contributed block type (test fixture): combines `required: true`,
  `editable_by:`, AND `default:` on the same field — the DSL allows
  `allow_nil?: false` and a `default:` together, so a required + restricted
  field CAN be reset to its declared default rather than forcing the whole
  block to be dropped (code-review finding #2 on the review following PR
  #1250/#935). `RestrictedRequiredBlock` (no default) is the case where a drop
  is the only option; this is the case where it is not.
  """
  use Kiln.Block

  block :restricted_required_default do
    field :locked_text, :string, required: true, editable_by: [:admin], default: "redacted"
  end

  @impl Kiln.Block.Renderer
  def render(block, :json),
    do: %{"_type" => "restricted_required_default", "locked_text" => block.locked_text}

  def render(_block, _surface), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block), do: block.locked_text || ""
end

defmodule KilnCMS.FixturePlugin.ChecklistBlock do
  @moduledoc """
  A plugin-contributed block type (test fixture) with a table-like
  `{:array, :map}` field declared through `item_keys:`, and the optional
  editor metadata (`label/0`, `icon/0`, `description/0`). Exercises the
  content editor's declared-row editor and palette copy for plugin blocks,
  which before these seams showed no input for the rows at all and listed the
  block as its raw name with the generic icon and description.
  """
  use Kiln.Block

  block :checklist do
    field :title, :string, description: "Shown above the list."
    field :items, {:array, :map}, default: [], item_keys: [:task, :owner]
  end

  @impl Kiln.Block.Renderer
  def render(block, :web) do
    items =
      for item <- List.wrap(block.items),
          is_map(item),
          do: ["<li>", esc(item["task"] || ""), "</li>"]

    [~s(<ul class="checklist">), items, "</ul>"]
  end

  def render(block, :json),
    do: %{"_type" => "checklist", "title" => block.title, "items" => block.items}

  def render(_block, _surface), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block),
    do: block.items |> List.wrap() |> Enum.map_join(" ", &(&1["task"] || ""))

  @impl Kiln.Block.Renderer
  def label, do: "Checklist"

  @impl Kiln.Block.Renderer
  def icon, do: "hero-check-circle"

  @impl Kiln.Block.Renderer
  def description, do: "Tasks with an owner each"

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end

defmodule KilnCMS.FixturePlugin.ProductCardBlock do
  @moduledoc """
  A plugin-contributed block type (test fixture) that opts fields into
  field-level localization (#1327): the image and price are one value for the
  whole document (`localized: :shared`), the caption falls back along the
  site's locale chain when a variant leaves it empty (`localized: :fallback`),
  and the name stays per locale, as every field always was. `in_stock` is a
  shared boolean.
  """
  use Kiln.Block

  block :product_card do
    field :name, :string
    field :image_url, :string, translatable: false, localized: :shared
    field :price, :integer, localized: :shared
    field :caption, :string, localized: :fallback
    # A shared boolean: the editor's checkbox ignores `readonly`, so it is
    # the case that has to be disabled on a translation instead (#1860).
    field :in_stock, :boolean, localized: :shared
  end

  @impl Kiln.Block.Renderer
  def render(block, :web),
    do: [
      ~s(<figure class="product-card"><figcaption>),
      esc(block.name || ""),
      " — ",
      esc(block.caption || ""),
      "</figcaption></figure>"
    ]

  def render(block, :json),
    do: %{
      "_type" => "product_card",
      "name" => block.name,
      "image_url" => block.image_url,
      "price" => block.price,
      "caption" => block.caption
    }

  def render(_block, _surface), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block),
    do: [block.name, block.caption] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

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
  def description, do: "One to five stars. For a review score."

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

defmodule KilnCMS.FixturePlugin.FieldTypes.Lookup do
  @moduledoc """
  A plugin field type with a client hook and a server callback (test fixture,
  #1918): `c:Kiln.FieldType.input_hook/1` names a colocated hook declared
  below, and `c:Kiln.FieldType.handle_input_event/3` answers it. Its events
  cover every outcome the editor has to relay: a reply, an error, a raise, a
  malformed return, and a slow call a newer event supersedes.
  """
  use Kiln.FieldType
  # Not just `import Phoenix.Component`: LiveView collects colocated hooks
  # only from modules that `use` it.
  use Phoenix.Component

  @impl Kiln.FieldType
  def cast(value, _definition), do: {:ok, to_string(value)}

  # A field named `explode_hook` raises here, so the editor's rescue (render
  # the plain input, drop the hook) has a case to prove it on. The doctor's
  # probe definition is named otherwise and sees the real hook.
  @impl Kiln.FieldType
  def input_hook(%{name: "explode_hook"}), do: raise("plugin hook blew up")

  def input_hook(_definition),
    do: %{hook: Kiln.FieldType.colocated_hook(__MODULE__, "Suggest"), data: %{min_chars: 3}}

  @impl Kiln.FieldType
  def handle_input_event("suggest", %{"q" => q}, %{definition: definition}),
    do: {:ok, %{suggestions: ["#{q} Street"], field: definition.name}}

  def handle_input_event("nothing", _params, _context), do: {:error, "no match"}
  def handle_input_event("boom", _params, _context), do: raise("lookup blew up")
  def handle_input_event("odd", _params, _context), do: :not_a_reply

  # Tells a test it has started (via a registered name, so the client payload
  # carries nothing process-shaped), then never returns.
  def handle_input_event("slow", _params, _context) do
    if probe = Process.whereis(:lookup_fixture_slow), do: send(probe, {:slow_started, self()})
    Process.sleep(:infinity)
  end

  # Never rendered: compiling it is what bundles the hook (see Kiln.FieldType,
  # "Client hooks").
  @doc false
  def __hooks__(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Suggest">
      export default {
        mounted() {
          this.ref = 0
          this.handleEvent("kiln:field_reply", ({field, ref, reply}) => {
            if (field !== this.el.dataset.field || ref !== this.ref) return
            this.el.dataset.suggestions = JSON.stringify(reply?.suggestions || [])
          })
          this.el.addEventListener("input", (e) => {
            this.pushEvent("kiln:field_event", {
              field: this.el.dataset.field, event: "suggest",
              params: {q: e.target.value}, ref: ++this.ref
            })
          })
        }
      }
    </script>
    """
  end
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
  def blocks,
    do: [
      KilnCMS.FixturePlugin.CalloutBlock,
      KilnCMS.FixturePlugin.RestrictedRequiredBlock,
      KilnCMS.FixturePlugin.RestrictedRequiredDefaultBlock,
      KilnCMS.FixturePlugin.ProductCardBlock,
      KilnCMS.FixturePlugin.ChecklistBlock
    ]

  @impl true
  def field_types,
    do: [
      KilnCMS.FixturePlugin.FieldTypes.Rating,
      KilnCMS.FixturePlugin.FieldTypes.Tokenless,
      KilnCMS.FixturePlugin.FieldTypes.Exploding,
      KilnCMS.FixturePlugin.FieldTypes.Lookup
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
