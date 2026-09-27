defmodule KilnCMSWeb.BlockComponents do
  @moduledoc """
  Renders content blocks to HTML. Shared by public delivery, the previews and
  the in-context editor. Each block is a map `view_blocks/1` builds from the
  typed blocks, with `:type` (string) and `:content`.

  Rich-text HTML and image URLs are sanitized via `KilnCMS.HTMLSanitizer`
  before rendering.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.HTMLSanitizer

  # The rendered width of an image block in the stock reading column.
  @column_image_sizes "(max-width: 768px) 100vw, 768px"

  @doc "The image `sizes` for a block laid out in the reading column."
  @spec column_image_sizes() :: String.t()
  def column_image_sizes, do: @column_image_sizes

  attr :block, :map, required: true
  # An image block's `sizes`. Delivery passes `100vw` for a theme that bleeds
  # images past the column (`KilnCMSWeb.ContentHTML.image_sizes/1`). Not
  # threaded into `columns` children, because a cell is never wider than the
  # column.
  attr :image_sizes, :string, default: @column_image_sizes
  # The experiment variant this page was rendered with (#499), threaded down so
  # a form block can carry it back on submission. `nil` on every ordinary page.
  attr :variant, :string, default: nil

  def render_block(%{block: %{type: type}} = assigns) do
    assigns = assign(assigns, :type, type)

    ~H"""
    <%!-- `data-block-id` is the anchor every surface that wants to point AT a
          block needs — comment pins in the shared preview (#802) first, and
          `KilnCMSWeb.InContextEditLive` already does the same thing with its
          own wrapper. `@block[:id]`, not `@block.id`: a legacy or hand-built
          block map may carry none, and Phoenix omits a nil attribute rather
          than emitting an empty one.

          It rides on public delivery too, since this is the shared render
          path. That is a block's own opaque id and nothing else — no comment,
          author or state travels with it, and `KilnCMS.CMS.Comment` stays
          unreachable from the public and headless surfaces. --%>
    <div class="kiln-block" data-block-id={@block[:id]}>
      <%= cond do %>
        <% @type == "heading" -> %>
          <%!-- `:anchor` is set only on public delivery
                (`KilnCMS.HeadingAnchors.anchor_tree/1`); the LiveView
                previews render without one. --%>
          <h2 id={@block[:anchor]} class="text-xl font-bold">{@block.content}</h2>
        <% @type == "rich_text" -> %>
          <%!-- `content` is sanitized-or-trusted at build time (the single
                boundary is the block's own `:web` serializer, see `view/1`);
                rendering it raw avoids re-parsing span-dense highlighted HTML
                on every request. --%>
          <div class="space-y-2">{Phoenix.HTML.raw(@block.content)}</div>
        <% @type == "quote" -> %>
          <blockquote class="border-l-4 border-base-300 pl-3 italic">{@block.content}</blockquote>
        <% @type == "image" -> %>
          <%!-- `<picture>` so a browser that supports WebP/AVIF takes the
                smaller encoding and every other one falls through to the `<img>`
                (#473). The `<source>`s are ordered most-efficient-first by
                `Media.Presentation.sources/1`, because the browser takes the
                first `type` it understands and stops looking. With no
                alternates the element degrades to exactly the `<img>` that was
                here before. --%>
          <picture :if={src = HTMLSanitizer.safe_image_src(@block.content)}>
            <source
              :for={source <- @block[:sources] || []}
              type={source.type}
              srcset={source.srcset}
              sizes={@image_sizes}
            />
            <img
              src={src}
              srcset={@block[:srcset]}
              sizes={@block[:srcset] && @image_sizes}
              alt={@block[:alt] || ""}
              width={@block[:width]}
              height={@block[:height]}
              style={@block[:focal]}
              loading="lazy"
              class="max-w-full rounded"
            />
          </picture>
        <% @type == "columns" -> %>
          <%!-- Nested-layout container (#335): a CSS grid whose cells each hold a
                recursively-rendered child block list. `style` is built from
                allowlisted layout/gap presets (KilnCMS.Blocks.Columns), so it's
                safe as an attribute value. --%>
          <div class="kiln-columns" style={@block[:style]}>
            <div :for={col <- @block[:columns] || []} class="kiln-column space-y-2">
              <.render_block :for={child <- col.blocks} block={child} variant={@variant} />
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
                <picture :if={src = HTMLSanitizer.safe_image_src(image[:url])}>
                  <source
                    :for={source <- image[:sources] || []}
                    type={source.type}
                    srcset={source.srcset}
                    sizes="(max-width: 768px) 50vw, 320px"
                  />
                  <img
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
                </picture>
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
          <.public_form :if={@block[:form]} form={@block[:form]} variant={@variant} />
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

  `values` and `errors` are the re-render after a refused submission (#1683):
  the visitor's own input filled back in, and `%{"field" => "message"}` from
  `KilnCMS.Forms.submit/3` shown inline against each field, with a focused
  summary at the top linking to every one. Both default to empty, which is the
  first render. `values` must only ever carry the admin-defined fields' string
  values — the caller builds it (`FormController`), and the honeypot is never
  among them: this component renders it empty unconditionally.
  """
  attr :form, :map, required: true
  attr :embed, :boolean, default: false
  # The experiment variant this page was rendered with (#499), or nil.
  attr :variant, :string, default: nil
  attr :values, :map, default: %{}, doc: "submitted string values by field name (#1683)"
  attr :errors, :map, default: %{}, doc: "field name => error message (#1683)"

  # The fill-time token (#477) to carry. nil mints a fresh one; a re-render
  # passes the visitor's original, still-valid token so the signal keeps
  # measuring from when they first saw the form rather than from the refusal.
  attr :rendered_at, :string, default: nil

  def public_form(assigns) do
    assigns =
      assigns
      |> assign(:id_prefix, "kiln-form-" <> assigns.form.slug)
      |> assign(:error_items, error_items(assigns.form, assigns.errors))

    ~H"""
    <form
      method="post"
      action={"/forms/" <> @form.slug}
      class="kiln-form space-y-4 rounded-lg border border-base-300 p-4"
    >
      <%!-- The error summary (#1683). `autofocus` moves focus here on load with
            no script (the page is a plain POST response), and `role="alert"`
            announces it; each item links to its field. --%>
      <div
        :if={@error_items != []}
        id={@id_prefix <> "-error-summary"}
        role="alert"
        tabindex="-1"
        autofocus
        aria-labelledby={@id_prefix <> "-error-summary-title"}
        class="rounded-lg border border-error/40 bg-error/5 p-4 focus:outline-none focus-visible:ring-2 focus-visible:ring-error"
      >
        <h2 id={@id_prefix <> "-error-summary-title"} class="text-sm font-semibold text-error">
          {gettext("There is a problem with your submission")}
        </h2>
        <ul class="mt-2 list-disc space-y-1 ps-5 text-sm">
          <li :for={item <- @error_items}>
            <a
              :if={item.anchor}
              href={"#" <> @id_prefix <> "-" <> item.anchor}
              class="text-error underline underline-offset-2"
            >
              {item.text}
            </a>
            <span :if={!item.anchor} class="text-error">{item.text}</span>
          </li>
        </ul>
      </div>

      <p :if={@form.description} class="text-sm text-base-content/70">{@form.description}</p>

      <%!-- Underscore-prefixed so it can't collide with an admin-defined field name. --%>
      <input :if={@embed} type="hidden" name="_kiln_embed" value="1" />

      <%!-- The fill-time spam signal (#477): a signed "now", so the submit
            handler can tell how long the visitor actually had the form open.
            Also underscore-prefixed. --%>
      <input
        type="hidden"
        name={KilnCMS.Forms.rendered_at_field()}
        value={@rendered_at || KilnCMS.Forms.rendered_at_token()}
      />

      <%!-- The A/B variant this page was rendered with (#499), so a conversion
            is attributed to the arm the visitor actually saw. This is what lets
            a form-submission goal work with no visitor cookie at all: the
            assignment travels with the page rather than with the person. --%>
      <input
        :if={@variant}
        type="hidden"
        name={KilnCMS.Forms.variant_field()}
        value={@variant}
      />

      <%!-- Honeypot: hidden from humans, irresistible to bots. --%>
      <div style="position:absolute;left:-9999px" aria-hidden="true">
        <label>
          {gettext("Leave this field empty")}
          <input type="text" name={KilnCMS.Forms.honeypot_field()} tabindex="-1" autocomplete="off" />
        </label>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-6">
        <div :for={field <- @form.fields} class={field_width_class(field)}>
          <.public_form_field
            field={field}
            id_prefix={@id_prefix}
            value={Map.get(@values, field.name, field.default_value)}
            error={Map.get(@errors, field.name)}
          />
        </div>
      </div>

      <button type="submit" class="btn btn-primary">
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

  # Scopes the input `id` the `<label for>` points at. `public_form/1` passes
  # the form's slug, so two forms on one page that share a field name (both
  # asking for `email`) still get distinct ids.
  attr :id_prefix, :string, default: "kiln-form"

  # What the input shows. `:default` is the first render (the field's own
  # `default_value`); a re-render after a refusal passes the submitted string.
  attr :value, :any, default: :default

  # The refusal message for this field from `KilnCMS.Forms.submit/3`, or nil.
  attr :error, :string, default: nil

  def public_form_field(assigns) do
    field_id = "#{assigns.id_prefix}-#{assigns.field.name}"
    error_id = assigns.error && field_id <> "-error"
    help_id = assigns.field.help_text && field_id <> "-help"

    current =
      case assigns.value do
        :default -> assigns.field.default_value
        value -> value
      end

    described_by =
      case Enum.reject([error_id, help_id], &is_nil/1) do
        [] -> nil
        ids -> Enum.join(ids, " ")
      end

    assigns =
      assign(assigns,
        field_id: field_id,
        error_id: error_id,
        help_id: help_id,
        current: current,
        described_by: described_by
      )

    ~H"""
    <label
      :if={@field.field_type != :boolean}
      for={@field_id}
      class="field-label mb-1 block text-sm font-medium"
    >
      {@field.label}
      <span :if={@field.required} class="text-error">
        <span aria-hidden="true">*</span>
        <span class="sr-only">{gettext("required")}</span>
      </span>
    </label>

    <%= case @field.field_type do %>
      <% :text -> %>
        <textarea
          id={@field_id}
          name={@field.name}
          required={@field.required}
          placeholder={@field.placeholder}
          aria-invalid={@error && "true"}
          aria-describedby={@described_by}
          class="field-input w-full"
        >{@current}</textarea>
      <% :select -> %>
        <select
          id={@field_id}
          name={@field.name}
          required={@field.required}
          aria-invalid={@error && "true"}
          aria-describedby={@described_by}
          class="field-select w-full"
        >
          <option value="">{gettext("Select…")}</option>
          <option :for={opt <- @field.options} value={opt} selected={opt == @current}>
            {opt}
          </option>
        </select>
      <% :boolean -> %>
        <label class="flex items-center gap-2 text-sm">
          <input type="hidden" name={@field.name} value="false" />
          <input
            id={@field_id}
            type="checkbox"
            name={@field.name}
            value="true"
            checked={@current == "true"}
            aria-invalid={@error && "true"}
            aria-describedby={@described_by}
          />
          <span class="font-medium">
            {@field.label}
            <span :if={@field.required} class="text-error">
              <span aria-hidden="true">*</span>
              <span class="sr-only">{gettext("required")}</span>
            </span>
          </span>
        </label>
      <% other -> %>
        <input
          id={@field_id}
          type={form_input_type(other)}
          name={@field.name}
          required={@field.required}
          placeholder={@field.placeholder}
          value={@current}
          aria-invalid={@error && "true"}
          aria-describedby={@described_by}
          class="field-input w-full"
        />
    <% end %>

    <p :if={@error} id={@error_id} class="mt-1 text-sm text-error">
      <span class="sr-only">{gettext("Error:")}</span>
      {form_error_message(@error)}
    </p>
    <p :if={@field.help_text} id={@help_id} class="mt-1 text-xs text-base-content/60">
      {@field.help_text}
    </p>
    """
  end

  # The summary's lines (#1683), in the form's own field order so it reads top
  # to bottom like the form, keyed to each field's LABEL (the raw `name` is an
  # admin's machine key, not something a visitor has ever seen). An error on no
  # field (`"form"`, when the form was switched off) has no anchor to link to
  # and goes last.
  defp error_items(_form, errors) when errors == %{}, do: []

  defp error_items(form, errors) do
    fields = Enum.filter(form.fields, &Map.has_key?(errors, &1.name))
    names = MapSet.new(fields, & &1.name)

    field_items =
      Enum.map(fields, fn field ->
        %{
          anchor: field.name,
          text:
            gettext("%{label}: %{message}",
              label: field.label,
              message: form_error_message(errors[field.name])
            )
        }
      end)

    other_items =
      errors
      |> Enum.reject(fn {name, _} -> MapSet.member?(names, name) end)
      |> Enum.sort()
      |> Enum.map(fn {_name, message} -> %{anchor: nil, text: form_error_message(message)} end)

    field_items ++ other_items
  end

  # `KilnCMS.Forms.submit/3` reports refusals as short English fragments. The
  # headless JSON API returns them verbatim as part of its response shape, so
  # they stay untranslated there; the HTML form is read by a person in the
  # page's locale, so the known ones become whole translated sentences here.
  # Anything unrecognised (a message added later) still shows, as-is.
  defp form_error_message("is required"), do: gettext("This field is required.")

  defp form_error_message("must be an email address"),
    do: gettext("Enter an email address, like name@example.com.")

  defp form_error_message("must be a whole number"), do: gettext("Enter a whole number.")

  defp form_error_message("must be a date (YYYY-MM-DD)"),
    do: gettext("Enter a date in the format YYYY-MM-DD.")

  defp form_error_message("is not one of the allowed options"),
    do: gettext("Choose one of the listed options.")

  defp form_error_message("is no longer accepting submissions"),
    do: gettext("This form is no longer accepting submissions.")

  defp form_error_message(message) when message in ["is not valid", "must be a boolean"],
    do: gettext("This value isn't valid.")

  defp form_error_message(message), do: to_string(message)

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
  The maps `render_block/1` takes, built straight from typed blocks (anything
  `KilnCMS.CMS.TypedBlocks.to_typed/1` accepts: structs, `%Ash.Union{}`s,
  stored or input maps).

  One map per block, with a string `:type`, `:content` (the block's primary
  text, sanitized HTML for rich text), its `:id`, and the data-side fields the
  renderer reads for that type. A `columns` block recurses, carrying its child
  tree and grid `:style`. Every surface renders from these — public delivery
  (which adds media and form enrichment on top, keyed by `:media_id` and
  `:form_slug`), the pop-out and token previews, the release preview and the
  in-context editor — so they cannot disagree about what a block shows.

  This used to go through `TypedBlocks.to_legacy/1` and then a second
  projection off the legacy `%{type, content, data}` shape (#1537). A block
  type with no clause of its own renders as an empty `custom` block, which is
  what that path gave it too.
  """
  @spec view_blocks([term()] | nil) :: [map()]
  def view_blocks(blocks) do
    blocks
    |> TypedBlocks.to_typed()
    |> Enum.map(&(&1 |> view() |> Map.put(:id, Map.get(&1, :id))))
  end

  defp view(%Blocks.Heading{} = b), do: %{type: "heading", content: b.text}

  # The single sanitize boundary for delivered and previewed rich text is the
  # block's own `:web` serializer: stored `legacy_html` is untrusted HTML and is
  # scrubbed there, while Portable Text renders trusted by construction.
  # `render_block/1` prints `content` raw, so rich-text HTML must never reach
  # it any other way.
  defp view(%Blocks.RichText{} = b),
    do: %{type: "rich_text", content: IO.iodata_to_binary(Blocks.render(b, :web) || "")}

  # The alt rides along so every surface shows the alt delivery ships, and
  # `media_id` so delivery can add the srcset, focal point and dimensions of the
  # library item (a loaded MediaItem is a delivery concern, not a preview one).
  defp view(%Blocks.Image{} = b),
    do: %{type: "image", content: b.url, alt: b.alt || "", media_id: b.media_id}

  defp view(%Blocks.Quote{} = b), do: %{type: "quote", content: b.text}

  # Embed metadata (#489) so the previews and the in-context editor show the
  # same card delivery does, rather than an empty figure.
  defp view(%Blocks.Embed{} = b) do
    %{
      type: "embed",
      content: b.url,
      title: b.title,
      author_name: b.author_name,
      provider_name: b.provider_name,
      thumbnail_url: b.thumbnail_url,
      resolved_url: b.resolved_url
    }
  end

  defp view(%Blocks.Divider{}), do: %{type: "divider", content: nil}

  defp view(%Blocks.Form{} = b),
    do: %{type: "form", content: b.form_slug, form_slug: b.form_slug}

  # Repeating-item blocks (#482): item keys are atoms, to match what
  # `render_block/1` reads; `:srcset`/`:focal` are delivery's to add.
  defp view(%Blocks.Gallery{} = b) do
    %{
      type: "gallery",
      content: b.title,
      style: Blocks.Gallery.layout_style(b.layout),
      images:
        for image <- Blocks.Gallery.images(b) do
          %{
            url: image["url"],
            alt: image["alt"],
            caption: image["caption"],
            media_id: image["media_id"]
          }
        end
    }
  end

  defp view(%Blocks.Accordion{} = b) do
    %{
      type: "accordion",
      content: b.title,
      first_open: b.first_open == true,
      panels: Blocks.Accordion.panels(b)
    }
  end

  # GEO blocks (#357): the data-side fields the renderer reads, so every
  # surface shows item rows and citations, not just the primary text.
  defp view(%Blocks.Faq{} = b), do: %{type: "faq", content: b.title, items: Blocks.Faq.items(b)}

  defp view(%Blocks.HowTo{} = b) do
    %{
      type: "how_to",
      content: b.name,
      description: b.description,
      steps: Blocks.HowTo.steps(b)
    }
  end

  defp view(%Blocks.Claim{} = b) do
    %{
      type: "claim",
      content: b.text,
      source_title: b.source_title,
      source_url: b.source_url
    }
  end

  defp view(%Blocks.Columns{} = b) do
    cols =
      for col <- List.wrap(b.columns), is_map(col) do
        %{blocks: col |> Map.get("blocks", Map.get(col, :blocks, [])) |> view_blocks()}
      end

    %{
      type: "columns",
      content: nil,
      columns: cols,
      style: Blocks.Columns.grid_style(b.layout, b.gap, length(cols))
    }
  end

  defp view(%Blocks.Custom{} = b), do: %{type: "custom", content: b.content}

  defp view(_block), do: %{type: "custom", content: nil}

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
