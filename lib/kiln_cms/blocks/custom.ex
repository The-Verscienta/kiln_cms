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

  # NB: match the bare struct and branch in the body. Block modules are Ash
  # embedded resources whose struct is built by a transformer at @before_compile,
  # so matching a struct *key* in a function head (%__MODULE__{legacy_type: ...})
  # fails on a clean compile ("__struct__/1 is undefined"). Bare %__MODULE__{} is
  # fine because Elixir resolves the current module's struct lazily.
  @impl Kiln.Block.Renderer
  def render(%__MODULE__{} = block, :web) do
    case block.legacy_type do
      "divider" -> ["<hr/>"]
      _ -> ["<!-- ", esc(block.legacy_type || "custom"), " block -->"]
    end
  end

  def render(%__MODULE__{} = block, :json) do
    %{
      "_type" => "custom",
      "legacy_type" => block.legacy_type,
      "content" => block.content,
      "data" => block.data || %{}
    }
  end

  def render(%__MODULE__{}, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{} = block) do
    case block.content do
      content when is_binary(content) ->
        content |> String.replace(~r/<[^>]*>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

      _ ->
        ""
    end
  end

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
