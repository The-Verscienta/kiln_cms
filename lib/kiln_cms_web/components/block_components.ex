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
        <% @type == "columns" -> %>
          <%!-- Nested-layout container (#335): a CSS grid whose cells each hold a
                recursively-rendered child block list. `style` is built from
                allowlisted layout/gap presets (KilnCMS.Blocks.Columns), so it's
                safe as an attribute value. --%>
          <div class="kiln-columns" style={@block[:style]}>
            <div :for={col <- @block[:columns] || []} class="kiln-column space-y-2">
              <.render_block :for={child <- col.blocks} block={child} />
            </div>
          </div>
        <% @type == "divider" -> %>
          <hr class="border-base-300" />
        <% @type == "form" -> %>
          <%!-- nil form (inactive/unknown slug) renders nothing on-site. --%>
          <.public_form :if={@block[:form]} form={@block[:form]} />
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

  @doc """
  The live public form for a form block (see `KilnCMS.CMS.Form`): one input
  per admin-defined field, a visually-hidden honeypot, POSTing to
  `/forms/<slug>` (no CSRF — the endpoint is anonymous and honeypot +
  rate-limited, and fired artifacts couldn't carry a token anyway).

  Set `embed` when rendering inside the iframe page (`/forms/:slug/embed`): it
  adds a hidden marker so the submit response knows to serve the framing-friendly
  CSP, otherwise the thank-you page would be blocked by `frame-ancestors 'self'`.
  Also shared with `KilnCMSWeb.FormHTML`, so new field types work in both places.
  """
  attr :form, :map, required: true
  attr :embed, :boolean, default: false

  def public_form(assigns) do
    ~H"""
    <form
      method="post"
      action={"/forms/" <> @form.slug}
      class="kiln-form space-y-4 rounded-lg border border-base-300 p-4"
    >
      <p :if={@form.description} class="text-sm text-base-content/70">{@form.description}</p>

      <%!-- Underscore-prefixed so it can't collide with an admin-defined field name. --%>
      <input :if={@embed} type="hidden" name="_kiln_embed" value="1" />

      <%!-- Honeypot: hidden from humans, irresistible to bots. --%>
      <div style="position:absolute;left:-9999px" aria-hidden="true">
        <label>
          {gettext("Leave this field empty")}
          <input type="text" name={KilnCMS.Forms.honeypot_field()} tabindex="-1" autocomplete="off" />
        </label>
      </div>

      <div :for={field <- @form.fields}>
        <label :if={field.field_type != :boolean} class="mb-1 block text-sm font-medium">
          {field.label}
          <span :if={field.required} aria-hidden="true" class="text-error">*</span>
        </label>

        <%= case field.field_type do %>
          <% :text -> %>
            <textarea
              name={field.name}
              required={field.required}
              class="w-full rounded border border-base-300 bg-transparent px-3 py-2 text-sm"
            ></textarea>
          <% :select -> %>
            <select
              name={field.name}
              required={field.required}
              class="w-full rounded border border-base-300 bg-transparent px-3 py-2 text-sm"
            >
              <option value="">—</option>
              <option :for={opt <- field.options} value={opt}>{opt}</option>
            </select>
          <% :boolean -> %>
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name={field.name} value="false" />
              <input type="checkbox" name={field.name} value="true" />
              <span class="font-medium">{field.label}</span>
            </label>
          <% other -> %>
            <input
              type={form_input_type(other)}
              name={field.name}
              required={field.required}
              class="w-full rounded border border-base-300 bg-transparent px-3 py-2 text-sm"
            />
        <% end %>

        <p :if={field.help_text} class="mt-1 text-xs text-base-content/60">{field.help_text}</p>
      </div>

      <button
        type="submit"
        class="rounded bg-primary px-4 py-2 text-sm font-medium text-primary-content"
      >
        {gettext("Submit")}
      </button>
    </form>
    """
  end

  defp form_input_type(:email), do: "email"
  defp form_input_type(:integer), do: "number"
  defp form_input_type(:date), do: "date"
  defp form_input_type(_), do: "text"

  @doc """
  Thin `%{type, content}` preview maps from legacy block maps (the shape the
  decoupled preview windows push over PubSub). A `columns` block recurses,
  carrying its child tree + grid `style` so the pop-out preview lays nested
  blocks out too — without the media/form enrichment the live delivery path adds.
  Shared by `PreviewLive` and the editor's decoupled preview so both agree.
  """
  @spec thin_blocks([map()]) :: [map()]
  def thin_blocks(legacy_maps), do: Enum.map(legacy_maps, &thin_block/1)

  defp thin_block(%{type: :columns, data: data}) do
    cols =
      for col <- data["columns"] || [] do
        children =
          col
          |> Map.get("blocks", [])
          |> KilnCMS.CMS.TypedBlocks.to_typed()
          |> KilnCMS.CMS.TypedBlocks.to_legacy()

        %{blocks: thin_blocks(children)}
      end

    %{
      type: "columns",
      content: nil,
      columns: cols,
      style: KilnCMS.Blocks.Columns.grid_style(data["layout"], data["gap"], length(cols))
    }
  end

  defp thin_block(block), do: %{type: to_string(block.type), content: block.content}
end
