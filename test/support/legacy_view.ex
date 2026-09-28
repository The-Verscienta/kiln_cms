defmodule KilnCMS.LegacyView do
  @moduledoc """
  Test-only: typed blocks projected to the pre-typed `%{type:, content:, data:,
  id:}` map, for terse assertions.

  This was `KilnCMS.CMS.TypedBlocks.to_legacy/1` until 1.0 removed it (#1543).
  Many tests assert on stored blocks in this shape ("the heading's `content` is
  `\"Title\"`"), and it is a readable one, so the projection moved here rather
  than into every assertion. Nothing in `lib/` may use it; production code
  renders from typed blocks (`KilnCMSWeb.BlockComponents.view_blocks/1`).
  """

  alias KilnCMS.Blocks.{Accordion, Claim, Columns, Custom, Divider, Embed, Faq, Form}
  alias KilnCMS.Blocks.{Gallery, Heading, HowTo, Image, Quote, RichText}

  @doc "A record's (or a list's) blocks, projected to legacy maps."
  def blocks(%{blocks: blocks}), do: blocks(blocks)

  def blocks(blocks) do
    blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> Enum.map(&one_to_legacy/1)
  end

  defp one_to_legacy(%Heading{} = b),
    do: %{type: :heading, content: b.text, data: %{"level" => b.level}, id: b.id}

  # The single sanitize boundary for delivered/previewed rich text: stored
  # legacy_html is untrusted editor/API HTML and is scrubbed HERE, at
  # payload/preview build time (cached on delivery), while PT-rendered HTML is
  # trusted by construction (escaped text + allowlisted URLs + closed markup).
  # BlockComponents renders `content` raw — it must never receive rich-text
  # HTML that didn't come through this function.
  defp one_to_legacy(%RichText{} = b),
    do: %{
      type: :rich_text,
      content: rich_text_content(b),
      data: %{},
      id: b.id
    }

  defp one_to_legacy(%Image{} = b),
    do: %{
      type: :image,
      content: b.url,
      data: %{"url" => b.url, "alt" => b.alt, "caption" => b.caption, "media_id" => b.media_id},
      id: b.id
    }

  defp one_to_legacy(%Quote{} = b),
    do: %{type: :quote, content: b.text, data: %{"citation" => b.citation}, id: b.id}

  defp one_to_legacy(%Embed{} = b),
    do: %{
      type: :embed,
      content: b.url,
      data: %{
        "title" => b.title,
        "author_name" => b.author_name,
        "provider_name" => b.provider_name,
        "thumbnail_url" => b.thumbnail_url,
        "resolved_url" => b.resolved_url,
        "resolved_at" => b.resolved_at
      },
      id: b.id
    }

  defp one_to_legacy(%Divider{} = b), do: %{type: :divider, content: nil, data: %{}, id: b.id}

  defp one_to_legacy(%Form{} = b),
    do: %{type: :form, content: b.form_slug, data: %{"form_slug" => b.form_slug}, id: b.id}

  # Repeating-item blocks (#482): heading in `content`, item list in `data` as a
  # raw map list, normalized through the block module so delivery never has to
  # tell a missing key from a blank one.
  defp one_to_legacy(%Gallery{} = b),
    do: %{
      type: :gallery,
      content: b.title,
      data: %{"layout" => b.layout, "images" => Gallery.images(b)},
      id: b.id
    }

  defp one_to_legacy(%Accordion{} = b),
    do: %{
      type: :accordion,
      content: b.title,
      data: %{"first_open" => b.first_open == true, "panels" => Accordion.panels(b)},
      id: b.id
    }

  # GEO blocks (#357): the primary text rides in `content`, the rest in `data`
  # (items/steps stay raw map lists — see the block modules).
  defp one_to_legacy(%Faq{} = b),
    do: %{type: :faq, content: b.title, data: %{"items" => KilnCMS.Blocks.Faq.items(b)}, id: b.id}

  defp one_to_legacy(%HowTo{} = b),
    do: %{
      type: :how_to,
      content: b.name,
      data: %{"description" => b.description, "steps" => KilnCMS.Blocks.HowTo.steps(b)},
      id: b.id
    }

  defp one_to_legacy(%Claim{} = b),
    do: %{
      type: :claim,
      content: b.text,
      data: %{
        "source_title" => b.source_title,
        "source_url" => b.source_url,
        "rating" => b.rating
      },
      id: b.id
    }

  # The container's layout + child tree ride in `data` (`content`/`children` stay
  # empty). Delivery reads `data["columns"]` to render the nested tree — see
  # `KilnCMSWeb.BlockComponents`.
  defp one_to_legacy(%Columns{} = b),
    do: %{
      type: :columns,
      content: nil,
      data: %{"layout" => b.layout, "gap" => b.gap, "columns" => b.columns || []},
      id: b.id
    }

  defp one_to_legacy(%Custom{} = b),
    do: %{type: to_type(b.legacy_type), content: b.content, data: b.data || %{}, id: b.id}

  # Total fallback. Every preview surface (`preview_live`, `token_preview_live`,
  # `release_preview_live`, the in-context editor, the editor's own pop-out
  # preview) funnels through here, so a block type with no clause above is a
  # crash on those pages rather than a missing block — and the set without one
  # grows every time a block is added (`video`, `audio`, `file` and now
  # `fragment` all lacked one). A content-free legacy block renders as nothing,
  # which is what these surfaces should show for a block they can't project.
  defp one_to_legacy(%_{} = block),
    do: %{type: :custom, content: nil, data: %{}, id: Map.get(block, :id)}

  defp rich_text_content(%RichText{legacy_html: html}) when is_binary(html) and html != "",
    do: KilnCMS.HTMLSanitizer.sanitize_rich_text(html)

  defp rich_text_content(%RichText{body: body}), do: KilnCMS.Blocks.PortableText.to_html(body)

  defp to_type(nil), do: :custom
  defp to_type(type) when is_atom(type), do: type

  defp to_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :custom
  end
end
