defmodule KilnCMS.Blocks.Form do
  @moduledoc """
  A form block: embeds an admin-defined public form (`KilnCMS.CMS.Form`, built
  at `/editor/forms`) into content by slug. On-site delivery renders the live
  form server-side (`BlockComponents` + the controller's form enrichment);
  fired `:web` artifacts carry a `data-kiln-form` placeholder that headless
  frontends hydrate from `GET /api/forms/:slug`.
  """
  use Kiln.Block

  block :form do
    field :form_slug, :string, required: true
  end

  # Match plain variables, never `%__MODULE__{}` — the struct is built at
  # @before_compile, so matching it breaks clean compiles (see divider.ex).
  @impl Kiln.Block.Renderer
  def render(block, :web),
    do: [~s(<div data-kiln-form="), esc(block.form_slug || ""), ~s("></div>)]

  def render(block, :json), do: %{"_type" => "form", "form_slug" => block.form_slug}

  def render(_block, _surface), do: nil

  @impl Kiln.Block.Renderer
  def search_text(_block), do: ""

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
