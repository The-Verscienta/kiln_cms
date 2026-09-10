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

import {
  createClient,
  isKilnHttpError,
  type ArtifactDocument,
  type Item,
  type ListOptions,
} from "@kiln-cms/client";

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
 * Drain a paginated `/published` feed. The server serves 25 rows by default
 * and caps a page at 100, so a single un-paged `list()` call would silently
 * truncate a site at 25 documents — page through instead.
 */
async function listAll(plural: string, options: ListOptions): Promise<SummaryItem[]> {
  const limit = 100;
  const all: SummaryItem[] = [];
  for (let offset = 0; ; offset += limit) {
    const { items } = await kiln.list<SummaryItem>(plural, {
      ...options,
      limit,
      offset,
      count: false,
    });
    all.push(...items);
    if (items.length < limit) return all;
  }
}

/**
 * Discover every published post and page for one locale from the JSON:API
 * `/published` feeds — metadata only (the block body is deliberately not
 * served on this surface; it comes from the artifact). The feed returns one
 * row per locale, so the build's locale is filtered here — without it, a
 * translation would be listed whose artifact fetch (pinned to `LOCALE`)
 * then misses.
 *
 * A custom compiled type (e.g. `mix kiln.gen.content product`) gets its own
 * route: add `listAll("products", { filter: { locale: LOCALE }, fields:
 * { product: ["title", "slug"] } })` here. Types created in the admin UI
 * share the generic `entries` surface — use `discoverEntries("<type name>")`
 * for those.
 */
export async function discoverContent(): Promise<ContentRef[]> {
  const [posts, pages] = await Promise.all([
    listAll("posts", { filter: { locale: LOCALE }, fields: { post: ["title", "slug"] } }),
    listAll("pages", { filter: { locale: LOCALE }, fields: { page: ["title", "slug"] } }),
  ]);

  return [...posts, ...pages].map((item) => ({
    type: item.type,
    slug: item.slug,
    title: item.title,
  }));
}

/**
 * Discover an admin-defined (dynamic) type's published documents. Dynamic
 * types share the `entries` JSON:API surface, scoped by `type_name` — and
 * their JSON:API resource type is the literal `"entry"`, so the delivery
 * `ContentRef.type` must be the dynamic type's *name* (which is what
 * `GET /api/content/:type/:slug` resolves), not `item.type`.
 */
export async function discoverEntries(typeName: string): Promise<ContentRef[]> {
  const entries = await listAll("entries", {
    filter: { type_name: typeName, locale: LOCALE },
    fields: { entry: ["title", "slug"] },
  });

  return entries.map((item) => ({ type: typeName, slug: item.slug, title: item.title }));
}

// ── published documents (refs + fired artifacts, shared by the pages) ───────

export interface PublishedDocument {
  ref: ContentRef;
  doc: ArtifactDocument;
}

let publishedPromise: Promise<PublishedDocument[]> | undefined;

/**
 * Every published document with its fired artifact — the single source of
 * truth both the index page and `getStaticPaths` render from, so the index
 * can never link a page that wasn't generated. Memoized: discovery and the
 * artifact fetches run once per build, not once per consuming page.
 */
export function publishedDocuments(): Promise<PublishedDocument[]> {
  return (publishedPromise ??= loadPublishedDocuments());
}

async function loadPublishedDocuments(): Promise<PublishedDocument[]> {
  const refs = await discoverContent();

  const documents = await Promise.all(
    refs.map(async (ref): Promise<PublishedDocument | null> => {
      try {
        const doc = await kiln.artifact<ArtifactDocument>(ref.type, ref.slug, {
          locale: LOCALE,
        });
        return { ref, doc };
      } catch (error) {
        // Listed but not servable (e.g. unpublished mid-build): drop it from
        // BOTH the index and the generated routes rather than failing the
        // build — or, worse, shipping an index link to a page that was never
        // generated.
        if (isKilnHttpError(error) && error.status === 404) return null;
        throw error;
      }
    }),
  );

  return documents.filter((entry): entry is PublishedDocument => entry !== null);
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
