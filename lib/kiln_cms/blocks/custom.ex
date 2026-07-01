defmodule KilnCMS.Blocks.Custom do
  @moduledoc """
  Catch-all typed block (Kiln v2 — D10). Carries any legacy/unmapped block
  (`divider`, `columns`, `custom`, or future unknowns) so the typed system and
  every serializer stay **total** over all content (decision A4). `legacy_type`
  preserves the original discriminator; `content`/`data` preserve the payload.
  """
  use Kiln.Block

  block :custom do
    field :legacy_type, :string
    field :content, :string
    field :data, :map, default: %{}
  end

  # Match a plain variable, not %__MODULE__{}. Block modules are Ash embedded
  # resources whose struct is built by a transformer at @before_compile — after
  # these heads compile — so a clean compile can't resolve %__MODULE__{} here at
  # all (not even the bare form): it raises "__struct__/1 is undefined". Read
  # fields in the body; KilnCMS.Blocks dispatches by struct type, so the argument
  # is always this block.
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    case block.legacy_type do
      "divider" -> ["<hr/>"]
      _ -> ["<!-- ", esc(block.legacy_type || "custom"), " block -->"]
    end
  end

  def render(block, :json) do
    %{
      "_type" => "custom",
      "legacy_type" => block.legacy_type,
      "content" => block.content,
      "data" => block.data || %{}
    }
  end

  def render(_block, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block) do
    case block.content do
      content when is_binary(content) ->
        content
        |> String.replace(~r/<[^>]*>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        ""
    end
  end

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
