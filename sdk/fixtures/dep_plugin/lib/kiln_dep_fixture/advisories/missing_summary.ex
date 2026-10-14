defmodule KilnDepFixture.Advisories.MissingSummary do
  @moduledoc """
  An advisory check compiled as a dependency (#1909). It matches both structs a
  check is handed, `Kiln.Advisory.Context` and its `Kiln.Advisory.Body`, which
  is what used to need the core at compile time.

  Deliberately not listed in the plugin's `advisories/0`: a registered check
  runs in every editor panel and would shift the pass counts other tests
  assert. The core's suite runs it by name against a context built from a real
  body walk.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Context

  @impl Kiln.Advisory
  def check(%Context{body: %Body{word_count: 0}}), do: :n_a

  def check(%Context{} = context) do
    case Context.field(context, :summary) do
      "" -> finding(:warning, :dep_missing_summary, :summary)
      _summary -> :ok
    end
  end

  @impl Kiln.Advisory
  def lenses, do: [:seo]
end
