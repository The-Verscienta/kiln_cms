/**
 * Render the `json` surface's typed blocks to HTML on the consumer side.
 *
 * This is deliberately a faithful port of KilnCMS's own server-side renderers
 * (`KilnCMS.Blocks.*` and `KilnCMS.Blocks.PortableText.to_html/1`) so you can see
 * exactly what a headless frontend has to do: walk the structured blocks and map
 * each `_type` to your own markup. (If you'd rather not render yourself, request
 * `?surface=web` and inject the server-rendered `{ "html": … }` instead.)
 */
import type { Block, PortableTextBlock, PortableTextMarkDef, PortableTextSpan } from "./kiln";

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ── Portable Text (rich_text body) ──────────────────────────────────────────

export function portableTextToHtml(blocks: PortableTextBlock[] | undefined): string {
  return (blocks ?? []).map(renderPortableTextBlock).join("");
}

function renderPortableTextBlock(block: PortableTextBlock): string {
  const defs = block.markDefs ?? [];
  const inner = (block.children ?? []).map((span) => renderSpan(span, defs)).join("");
  const style = block.style ?? "normal";

  if (style === "blockquote") return `<blockquote>${inner}</blockquote>`;
  if (/^h[1-6]$/.test(style)) return `<${style}>${inner}</${style}>`;
  return `<p>${inner}</p>`;
}

function renderSpan(span: PortableTextSpan, defs: PortableTextMarkDef[]): string {
  let html = escapeHtml(span.text ?? "");
  for (const mark of span.marks ?? []) {
    html = applyMark(mark, html, defs);
  }
  return html;
}

function applyMark(mark: string, inner: string, defs: PortableTextMarkDef[]): string {
  switch (mark) {
    case "strong":
      return `<strong>${inner}</strong>`;
    case "em":
      return `<em>${inner}</em>`;
    case "code":
      return `<code>${inner}</code>`;
    case "strike":
      return `<s>${inner}</s>`;
    case "underline":
      return `<u>${inner}</u>`;
    default: {
      // Otherwise it's a key into markDefs — currently only link annotations.
      const def = defs.find((d) => d._key === mark);
      if (def?._type === "link" && def.href) {
        return `<a href="${escapeHtml(def.href)}">${inner}</a>`;
      }
      return inner;
    }
  }
}

// ── typed blocks ────────────────────────────────────────────────────────────

/** Render a single typed block to an HTML string. Unknown types are skipped. */
export function renderBlock(block: Block): string {
  switch (block._type) {
    case "rich_text":
      return portableTextToHtml((block as Extract<Block, { _type: "rich_text" }>).body);

    case "heading": {
      const b = block as Extract<Block, { _type: "heading" }>;
      const level = b.level >= 1 && b.level <= 6 ? b.level : 2;
      return `<h${level}>${escapeHtml(b.text)}</h${level}>`;
    }

    case "image": {
      const b = block as Extract<Block, { _type: "image" }>;
      const img = `<img src="${escapeHtml(b.url)}" alt="${escapeHtml(b.alt ?? "")}" loading="lazy" />`;
      const caption = b.caption ? `<figcaption>${escapeHtml(b.caption)}</figcaption>` : "";
      return `<figure>${img}${caption}</figure>`;
    }

    case "quote": {
      const b = block as Extract<Block, { _type: "quote" }>;
      const cite = b.citation ? `<cite>${escapeHtml(b.citation)}</cite>` : "";
      return `<blockquote><p>${escapeHtml(b.text)}</p>${cite}</blockquote>`;
    }

    case "divider":
      return "<hr />";

    case "embed": {
      const b = block as Extract<Block, { _type: "embed" }>;
      return `<p class="embed"><a href="${escapeHtml(b.url)}" rel="noopener">${escapeHtml(b.url)}</a></p>`;
    }

    default:
      // Forward-compatible: a block type this consumer doesn't know about yet.
      return "";
  }
}

/** Render a document's whole block list to an HTML string. */
export function renderBlocks(blocks: Block[]): string {
  return blocks.map(renderBlock).join("\n");
}
