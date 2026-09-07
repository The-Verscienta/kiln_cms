/**
 * The site's Kiln client — a thin wrapper over the official
 * `@kiln-cms/client` package (clients/js in the KilnCMS repo).
 *
 * The client wraps the delivery surfaces this example uses:
 *
 *   - JSON:API reads (`GET /api/json/...`) — discovery: published lists with
 *     slug/title metadata, and per-type search. Published-only by default.
 *   - Fired artifacts (`GET /api/content/:type/:slug?surface=json`) — the
 *     immutable, pre-serialized blocks a document compiled to on publish.
 *
 * Published content is world-readable, so no API key is configured here.
 * For per-site generated types (dynamic content types and custom fields
 * included), run the bundled generator against your running instance:
 *
 *     npx kiln-types --url $KILN_API_URL --out src/kiln-types.d.ts
 */

import { createClient, type Item } from "@kiln-cms/client";

// Re-exported for the block renderer (`render.ts`) and the pages.
export type {
  Block,
  PortableTextBlock,
  PortableTextMarkDef,
  PortableTextSpan,
} from "@kiln-cms/client";
export type { ArtifactDocument as Document } from "@kiln-cms/client";

// ── configuration ──────────────────────────────────────────────────────────

/** Base URL of the running KilnCMS instance, e.g. http://localhost:4000. */
export const API_URL: string = (
  import.meta.env.KILN_API_URL ??
  (typeof process !== "undefined" ? process.env.KILN_API_URL : undefined) ??
  "http://localhost:4000"
).replace(/\/+$/, "");

/** Locale to build (KilnCMS default is "en"). */
export const LOCALE: string =
  import.meta.env.KILN_LOCALE ??
  (typeof process !== "undefined" ? process.env.KILN_LOCALE : undefined) ??
  "en";

export const kiln = createClient({ baseUrl: API_URL });

// ── content discovery (JSON:API published lists) ────────────────────────────

/** A reference to a published document, from the JSON:API metadata surface. */
export interface ContentRef {
  /** Singular content-type name as the delivery API expects it: "page", "post", … */
  type: string;
  slug: string;
  title: string;
}

/** The JSON:API attributes this example reads off a list item. */
interface SummaryItem extends Item {
  slug: string;
  title: string;
}

/**
 * Discover every published post and page from the JSON:API `/published`
 * feeds — one request per content type, metadata only (the block body is
 * deliberately not served on this surface; it comes from the artifact).
 *
 * Content types created in the admin UI share the generic `entries` surface —
 * to include one here, add `kiln.list("entries", { filter: { type_name: "…" } })`.
 */
export async function discoverContent(): Promise<ContentRef[]> {
  const [posts, pages] = await Promise.all([
    kiln.list<SummaryItem>("posts", { fields: { post: ["title", "slug"] } }),
    kiln.list<SummaryItem>("pages", { fields: { page: ["title", "slug"] } }),
  ]);

  return [...posts.items, ...pages.items].map((item) => ({
    type: item.type,
    slug: item.slug,
    title: item.title,
  }));
}

// ── search (JSON:API published search twin) ────────────────────────────────

/** A search hit — the metadata this example renders for a match. */
export interface PostSummary {
  title: string;
  slug: string;
  excerpt: string | null;
}

/**
 * Search published posts through the JSON:API `/search/published` twin
 * (relevance-ranked, published-only server-side).
 */
export async function searchPosts(
  query: string,
  locale: string = LOCALE,
): Promise<PostSummary[]> {
  const { items } = await kiln.textSearch<SummaryItem & { excerpt?: string | null }>(
    "posts",
    query,
    { locale },
  );

  return items.map((item) => ({
    title: item.title,
    slug: item.slug,
    excerpt: item.excerpt ?? null,
  }));
}
