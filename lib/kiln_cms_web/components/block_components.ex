defmodule KilnCMSWeb.BlockComponents do
  @moduledoc """
  Renders content blocks to HTML. Shared by the editor's live preview and
  (later) public delivery. Each block is a plain map with `:type` (string) and
  `:content`.

  Note: `rich_text` content is rendered raw (authored by trusted editors).
  Sanitize before using this for untrusted/public input.
  """
  use Phoenix.Component

  attr :block, :map, required: true

  def render_block(%{block: %{type: type}} = assigns) do
    assigns = assign(assigns, :type, type)

    ~H"""
    <div class="kiln-block">
      <%= cond do %>
        <% @type == "heading" -> %>
          <h2 class="text-xl font-bold">{@block.content}</h2>
        <% @type == "rich_text" -> %>
          <div class="space-y-2">{Phoenix.HTML.raw(@block.content)}</div>
        <% @type == "quote" -> %>
          <blockquote class="border-l-4 border-base-300 pl-3 italic">{@block.content}</blockquote>
        <% @type == "image" -> %>
          <img src={@block.content} alt="" class="max-w-full rounded" />
        <% @type == "divider" -> %>
          <hr class="border-base-300" />
        <% @type == "embed" -> %>
          <div class="rounded bg-base-200 p-2 text-sm text-base-content/60">
            Embed: {@block.content}
          </div>
        <% true -> %>
          <p>{@block.content}</p>
      <% end %>
    </div>
    """
  end
end
