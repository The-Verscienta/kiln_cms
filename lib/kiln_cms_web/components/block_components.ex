defmodule KilnCMSWeb.BlockComponents do
  @moduledoc """
  Renders content blocks to HTML. Shared by the editor's live preview and
  (later) public delivery. Each block is a plain map with `:type` (string) and
  `:content`.

  Rich-text HTML and image URLs are sanitized via `KilnCMS.HTMLSanitizer`
  before rendering.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.HTMLSanitizer

  attr :block, :map, required: true

  def render_block(%{block: %{type: type}} = assigns) do
    assigns = assign(assigns, :type, type)

    ~H"""
    <div class="kiln-block">
      <%= cond do %>
        <% @type == "heading" -> %>
          <h2 class="text-xl font-bold">{@block.content}</h2>
        <% @type == "rich_text" -> %>
          <div class="space-y-2">{HTMLSanitizer.rich_text_raw(@block.content)}</div>
        <% @type == "quote" -> %>
          <blockquote class="border-l-4 border-base-300 pl-3 italic">{@block.content}</blockquote>
        <% @type == "image" -> %>
          <img
            :if={src = HTMLSanitizer.safe_image_src(@block.content)}
            src={src}
            srcset={@block[:srcset]}
            sizes={@block[:srcset] && "(max-width: 768px) 100vw, 768px"}
            alt={@block[:alt] || ""}
            width={@block[:width]}
            height={@block[:height]}
            style={@block[:focal]}
            loading="lazy"
            class="max-w-full rounded"
          />
        <% @type == "divider" -> %>
          <hr class="border-base-300" />
        <% @type == "embed" -> %>
          <div :if={embed = HTMLSanitizer.safe_embed_url(@block.content)} class="aspect-video">
            <iframe
              src={embed}
              title={gettext("Embedded media")}
              class="h-full w-full rounded"
              allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
              allowfullscreen
            />
          </div>
        <% true -> %>
          <p>{@block.content}</p>
      <% end %>
    </div>
    """
  end
end
