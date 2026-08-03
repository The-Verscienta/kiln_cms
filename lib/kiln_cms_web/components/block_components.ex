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
          <%!-- `content` is sanitized-or-trusted at build time (the single
                boundary in TypedBlocks.one_to_legacy); rendering it raw avoids
                re-parsing span-dense highlighted HTML on every request. --%>
          <div class="space-y-2">{Phoenix.HTML.raw(@block.content)}</div>
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
        <% @type == "gallery" -> %>
          <%!-- Image collection (#482): heading in content, items in :images.
                `style` comes from an allowlisted layout key
                (KilnCMS.Blocks.Gallery.layout_style/1), so it is safe as an
                attribute value — same rule the columns grid follows. Each item
                carries its own srcset/focal/dimensions, resolved by delivery's
                batch media load. --%>
          <section class="kiln-gallery space-y-2">
            <h2 :if={@block.content not in [nil, ""]} class="text-xl font-bold">{@block.content}</h2>
            <div class="kiln-gallery-items" style={@block[:style]}>
              <%!-- Filtered, not guarded per-element: the block's own `:web`
                    serializer drops url-less items entirely, and guarding only
                    the `<img>` would leave an empty captioned figure here that
                    the fired artifact does not have. --%>
              <figure
                :for={image <- gallery_images(@block)}
                class="kiln-gallery-item m-0"
              >
                <img
                  :if={src = HTMLSanitizer.safe_image_src(image[:url])}
                  src={src}
                  srcset={image[:srcset]}
                  sizes={image[:srcset] && "(max-width: 768px) 50vw, 320px"}
                  alt={image[:alt] || ""}
                  width={image[:width]}
                  height={image[:height]}
                  style={image[:focal]}
                  loading="lazy"
                  class="w-full rounded"
                />
                <figcaption
                  :if={image[:caption] not in [nil, ""]}
                  class="mt-1 text-sm text-base-content/70"
                >
                  {image[:caption]}
                </figcaption>
              </figure>
            </div>
          </section>
        <% @type == "accordion" -> %>
          <%!-- Collapsible panels (#482). Deliberately identical in markup to the
                faq branch below and deliberately different in meaning: this one
                contributes nothing to the structured-data graph. See
                KilnCMS.Blocks.Accordion. --%>
          <section class="kiln-accordion space-y-2">
            <h2 :if={@block.content not in [nil, ""]} class="text-xl font-bold">{@block.content}</h2>
            <%!-- Indexed AFTER filtering, matching the block's own serializer.
                  Indexing first would open panel zero of the raw list — so a
                  blank leading row (one click too many on "Add panel") leaves
                  the on-site page with nothing open while the fired artifact
                  opens the first real panel. --%>
            <details
              :for={{panel, index} <- Enum.with_index(accordion_panels(@block))}
              open={index == 0 && @block[:first_open] == true}
              class="kiln-accordion-item rounded border border-base-300 p-2"
            >
              <summary class="cursor-pointer font-medium">{panel["title"]}</summary>
              <p class="mt-1">{panel["content"]}</p>
            </details>
          </section>
        <% @type == "faq" -> %>
          <%!-- GEO Q&A block (#357): title in content, item rows in :items. --%>
          <section class="kiln-faq space-y-2">
            <h2 :if={@block.content not in [nil, ""]} class="text-xl font-bold">{@block.content}</h2>
            <details
              :for={item <- @block[:items] || []}
              :if={item["question"] not in [nil, ""]}
              class="kiln-faq-item rounded border border-base-300 p-2"
            >
              <summary class="cursor-pointer font-medium">{item["question"]}</summary>
              <p class="mt-1">{item["answer"]}</p>
            </details>
          </section>
        <% @type == "how_to" -> %>
          <%!-- GEO step-by-step block (#357): name in content, rows in :steps. --%>
          <section class="kiln-howto space-y-2">
            <h2 :if={@block.content not in [nil, ""]} class="text-xl font-bold">{@block.content}</h2>
            <p :if={@block[:description] not in [nil, ""]} class="text-base-content/80">
              {@block[:description]}
            </p>
            <ol class="list-decimal space-y-1 pl-5">
              <li :for={step <- @block[:steps] || []} :if={step["text"] not in [nil, ""]}>
                <strong :if={step["name"] not in [nil, ""]}>{step["name"]}</strong>
                {step["text"]}
              </li>
            </ol>
          </section>
        <% @type == "claim" -> %>
          <%!-- GEO sourced claim (#357): the citation renders inline on-site too. --%>
          <p class="kiln-claim">
            {@block.content}
            <cite :if={@block[:source_title] || @block[:source_url]} class="text-sm">
              <%= if href = HTMLSanitizer.safe_href(@block[:source_url]) do %>
                <a href={href} rel="noopener" class="underline">
                  {@block[:source_title] || href}
                </a>
              <% else %>
                {@block[:source_title]}
              <% end %>
            </cite>
          </p>
        <% @type == "divider" -> %>
          <hr class="border-base-300" />
        <% @type == "form" -> %>
          <%!-- nil form (inactive/unknown slug) renders nothing on-site. --%>
          <.public_form :if={@block[:form]} form={@block[:form]} />
        <% @type == "embed" -> %>
          <%!-- Two shapes, and only the allowlisted hosts get an iframe. --%>
          <div :if={embed = HTMLSanitizer.safe_embed_url(@block.content)} class="aspect-video">
            <iframe
              src={embed}
              title={@block[:title] || gettext("Embedded media")}
              class="h-full w-full rounded"
              allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
              allowfullscreen
            />
          </div>
          <%!-- Everything else with resolved oEmbed metadata renders as a card
                (#489): a link, a thumbnail and a title, all escaped scalars. The
                provider's own `html` is never used — see KilnCMS.OEmbed. An
                embed with no metadata falls through to nothing, which is what it
                rendered before the feature existed. --%>
          <a
            :if={embed_card?(@block)}
            href={HTMLSanitizer.safe_href(@block.content)}
            rel="noopener"
            class="kiln-embed-card flex gap-3 rounded border border-base-300 p-3 no-underline hover:bg-base-200"
          >
            <img
              :if={thumb = HTMLSanitizer.safe_image_src(@block[:thumbnail_url])}
              src={thumb}
              alt=""
              loading="lazy"
              class="size-20 shrink-0 rounded object-cover"
            />
            <span class="min-w-0">
              <span class="block font-medium">{@block[:title]}</span>
              <span :if={byline = embed_byline(@block)} class="block text-sm text-base-content/70">
                {byline}
              </span>
            </span>
          </a>
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

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-6">
        <div :for={field <- @form.fields} class={field_width_class(field)}>
          <.public_form_field field={field} />
        </div>
      </div>

      <button
        type="submit"
        class="rounded bg-primary px-4 py-2 text-sm font-medium text-primary-content"
      >
        {@form.submit_label || gettext("Submit")}
      </button>
    </form>
    """
  end

  @doc """
  One admin-defined field of a public form: label, input (typed, with
  placeholder/default), and help text. Extracted from `public_form/1` so the
  form builder's canvas (`FormBuilderLive`) renders the exact same markup —
  the preview can't drift from the public form.
  """
  attr :field, :map, required: true

  def public_form_field(assigns) do
    ~H"""
    <label :if={@field.field_type != :boolean} class="mb-1 block text-sm font-medium">
      {@field.label}
      <span :if={@field.required} aria-hidden="true" class="text-error">*</span>
    </label>

    <%= case @field.field_type do %>
      <% :text -> %>
        <textarea
          name={@field.name}
          required={@field.required}
          placeholder={@field.placeholder}
          class="w-full rounded border border-base-300 bg-transparent px-3 py-2 text-sm"
        >{@field.default_value}</textarea>
      <% :select -> %>
        <select
          name={@field.name}
          required={@field.required}
          class="w-full rounded border border-base-300 bg-transparent px-3 py-2 text-sm"
        >
          <option value="">—</option>
          <option :for={opt <- @field.options} value={opt} selected={opt == @field.default_value}>
            {opt}
          </option>
        </select>
      <% :boolean -> %>
        <label class="flex items-center gap-2 text-sm">
          <input type="hidden" name={@field.name} value="false" />
          <input
            type="checkbox"
            name={@field.name}
            value="true"
            checked={@field.default_value == "true"}
          />
          <span class="font-medium">
            {@field.label}
            <span :if={@field.required} aria-hidden="true" class="text-error">*</span>
          </span>
        </label>
      <% other -> %>
        <input
          type={form_input_type(other)}
          name={@field.name}
          required={@field.required}
          placeholder={@field.placeholder}
          value={@field.default_value}
          class="w-full rounded border border-base-300 bg-transparent px-3 py-2 text-sm"
        />
    <% end %>

    <p :if={@field.help_text} class="mt-1 text-xs text-base-content/60">{@field.help_text}</p>
    """
  end

  @doc """
  The field's column span on the public form's 6-column grid (`width` on
  `KilnCMS.CMS.FormField`). Shared with the builder canvas.
  """
  @spec field_width_class(map()) :: String.t()
  def field_width_class(%{width: :half}), do: "sm:col-span-3"
  def field_width_class(%{width: :third}), do: "sm:col-span-2"
  def field_width_class(_field), do: "sm:col-span-6"

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

  # An image's alt rides along so surfaces that render from the thin shape — the
  # pop-out preview, the in-context edit overlay — show the same alt text
  # delivery will. `srcset`/`focal` deliberately do not: those need a loaded
  # MediaItem, which is a delivery concern.
  # Embed metadata (#489) rides the thin shape so the previews and the
  # in-context editor show the same card delivery does, rather than an empty
  # figure while the real page shows a title and a thumbnail.
  defp thin_block(%{type: :embed, content: content, data: data}) do
    %{
      type: "embed",
      content: content,
      title: data["title"],
      author_name: data["author_name"],
      provider_name: data["provider_name"],
      thumbnail_url: data["thumbnail_url"],
      resolved_url: data["resolved_url"]
    }
  end

  defp thin_block(%{type: :image, content: content, data: data}),
    do: %{type: "image", content: content, alt: data["alt"] || ""}

  # Repeating-item blocks (#482). The thin shape carries no media enrichment —
  # `thin_blocks/1` serves the pop-out preview and the editor, which render from
  # the stored url rather than from a batch-loaded MediaItem — so item keys are
  # atoms here to match what `render_block/1` reads, and `:srcset`/`:focal` are
  # simply absent (the `:if` guards handle that).
  defp thin_block(%{type: :gallery, content: content, data: data}) do
    %{
      type: "gallery",
      content: content,
      style: KilnCMS.Blocks.Gallery.layout_style(data["layout"]),
      images:
        for image <- data["images"] || [], is_map(image) do
          %{url: image["url"], alt: image["alt"], caption: image["caption"]}
        end
    }
  end

  defp thin_block(%{type: :accordion, content: content, data: data}) do
    %{
      type: "accordion",
      content: content,
      first_open: data["first_open"] == true,
      panels: data["panels"] || []
    }
  end

  # GEO blocks (#357): carry the data-side fields the renderer reads, so the
  # pop-out preview shows item rows and citations, not just the primary text.
  defp thin_block(%{type: :faq, content: content, data: data}),
    do: %{type: "faq", content: content, items: data["items"] || []}

  defp thin_block(%{type: :how_to, content: content, data: data}) do
    %{
      type: "how_to",
      content: content,
      description: data["description"],
      steps: data["steps"] || []
    }
  end

  defp thin_block(%{type: :claim, content: content, data: data}) do
    %{
      type: "claim",
      content: content,
      source_title: data["source_title"],
      source_url: data["source_url"]
    }
  end

  defp thin_block(block), do: %{type: to_string(block.type), content: block.content}

  # The items each renderable surface actually shows, filtered the same way the
  # block modules' own `:web` serializers filter. Two renderers over one block
  # that disagree about which items count is a bug that only shows up as "the
  # published page looks different from the preview".
  defp gallery_images(block) do
    for image <- block[:images] || [], present?(image[:url]), do: image
  end

  defp accordion_panels(block) do
    for panel <- block[:panels] || [], present?(panel["title"]), do: panel
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # One predicate, shared with the block module's own `card?/1`, so the fired
  # artifact and the live site cannot disagree about when a card exists — the
  # drift the #482 review found between the gallery/accordion renderers.
  defp embed_card?(block) do
    is_nil(HTMLSanitizer.safe_embed_url(block.content)) and
      KilnCMS.Blocks.Embed.card?(%KilnCMS.Blocks.Embed{
        url: block.content,
        title: block[:title],
        resolved_url: block[:resolved_url]
      })
  end

  # "Provider · Author", omitting whichever is missing, nil when both are.
  defp embed_byline(block) do
    case [block[:provider_name], block[:author_name]] |> Enum.filter(&present?/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end
end
