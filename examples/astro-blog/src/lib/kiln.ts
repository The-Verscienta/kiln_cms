/**
 * Tiny typed client for the KilnCMS headless delivery API.
 *
 * KilnCMS exposes published content through three public surfaces, all used here:
 *
 *   1. `GET /sitemap.xml`                          — enumerate every published URL
 *   2. `GET /api/content/:type/:slug?surface=json` — the v2 content delivery API
 *      (decision D9): the immutable, pre-serialized artifact a document compiled
 *      to on publish. Surfaces: `json` (structured intent, used here), `json_ld`
 *      (schema.org graph), `web` (`{ "html": "…" }`).
 *   3. `POST /gql`                                 — AshGraphql, used for search.
 *
 * Published content is world-readable, so none of these require authentication.
 */

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

// ── types ──────────────────────────────────────────────────────────────────

/** A Portable Text span — a run of text carrying zero or more `marks`. */
export interface PortableTextSpan {
  _type: "span";
  text: string;
  marks?: string[];
}

/** A Portable Text mark definition (e.g. a link annotation), keyed by `_key`. */
export interface PortableTextMarkDef {
  _key: string;
  _type: string;
  href?: string;
  [key: string]: unknown;
}

/** A Portable Text block (paragraph / heading / blockquote) of spans. */
export interface PortableTextBlock {
  _type: "block";
  _key?: string;
  /** "normal" | "h1".."h6" | "blockquote" */
  style?: string;
  children?: PortableTextSpan[];
  markDefs?: PortableTextMarkDef[];
}

/**
 * A typed content block as serialized by the `json` surface. The first members
 * are the v1 block types; the index-signature fallback keeps the client
 * forward-compatible with block types added later (custom blocks, etc.).
 */
export type Block =
  | { _type: "rich_text"; body: PortableTextBlock[] }
  | { _type: "heading"; text: string; level: number }
  | { _type: "image"; url: string; alt?: string | null; caption?: string | null }
  | { _type: "quote"; text: string; citation?: string | null }
  | { _type: "divider" }
  | { _type: "embed"; url: string }
  | { _type: string; [key: string]: unknown };

/** A published document, as returned by `?surface=json`. */
export interface Document {
  type: string;
  title: string;
  slug: string;
  blocks: Block[];
}

/** A reference to a published document, derived from the sitemap. */
export interface ContentRef {
  /** Singular content-type atom as the delivery API expects it: "page", "post", … */
  type: string;
  slug: string;
  lastmod?: string;
}

/** A search hit from the GraphQL `searchPosts` query. */
export interface PostSummary {
  title: string;
  slug: string;
  excerpt: string | null;
}

// ── content discovery (sitemap.xml) ─────────────────────────────────────────

/**
 * Map a public URL from the sitemap to the `{ type, slug }` the delivery API
 * uses. KilnCMS serves pages at `/<slug>`, posts at `/blog/<slug>`, and any
 * other content type at `/<plural>/<slug>` (see `ContentTypes.public_prefix/1`).
 *
 * Add an entry here for each custom content type whose URL segment isn't just
 * the singular type + "s" (posts being the built-in special case).
 */
const SEGMENT_TO_TYPE: Record<string, string> = {
  blog: "post",
};

function locToRef(loc: string, lastmod?: string): ContentRef | null {
  let pathname: string;
  try {
    pathname = new URL(loc).pathname;
  } catch {
    pathname = loc;
  }

  const segments = pathname.replace(/^\/+|\/+$/g, "").split("/").filter(Boolean);
  if (segments.length === 0) return null;

  // Pages live at the root: `/welcome`.
  if (segments.length === 1) {
    return { type: "page", slug: segments[0], lastmod };
  }

  // Other types live under a prefix segment: `/blog/hello-world`, `/products/x`.
  const [segment, ...rest] = segments;
  const slug = rest[rest.length - 1];
  const type = SEGMENT_TO_TYPE[segment] ?? segment.replace(/s$/, "");
  return { type, slug, lastmod };
}

/**
 * Discover every published document by parsing `sitemap.xml`. Returns one
 * `ContentRef` per published URL.
 */
export async function discoverContent(): Promise<ContentRef[]> {
  const res = await fetch(`${API_URL}/sitemap.xml`);
  if (!res.ok) {
    throw new Error(
      `Could not fetch ${API_URL}/sitemap.xml (${res.status}). Is KilnCMS running and seeded?`,
    );
  }

  const xml = await res.text();
  const refs: ContentRef[] = [];

  for (const block of xml.match(/<url>[\s\S]*?<\/url>/g) ?? []) {
    const loc = block.match(/<loc>([\s\S]*?)<\/loc>/)?.[1]?.trim();
    if (!loc) continue;
    const lastmod = block.match(/<lastmod>([\s\S]*?)<\/lastmod>/)?.[1]?.trim();
    const ref = locToRef(decodeXmlEntities(loc), lastmod);
    if (ref) refs.push(ref);
  }

  return refs;
}

function decodeXmlEntities(value: string): string {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

// ── content delivery (/api/content) ─────────────────────────────────────────

export type Surface = "json" | "json_ld" | "web";

/**
 * Fetch the fired artifact for a document. With the default `json` surface this
 * resolves to a `Document`; pass another surface to get its raw body shape.
 */
export async function fetchArtifact(
  ref: ContentRef,
  surface: Surface = "json",
  locale: string = LOCALE,
): Promise<Document | null> {
  const url = `${API_URL}/api/content/${encodeURIComponent(ref.type)}/${encodeURIComponent(
    ref.slug,
  )}?surface=${surface}&locale=${encodeURIComponent(locale)}`;

  const res = await fetch(url);
  if (!res.ok) return null;
  return (await res.json()) as Document;
}

// ── search (GraphQL) ────────────────────────────────────────────────────────

/**
 * Search published posts via the AshGraphql `searchPosts` query. Returns title /
 * slug / excerpt for each hit (link the slug to the post's page).
 */
export async function searchPosts(
  query: string,
  locale: string = LOCALE,
): Promise<PostSummary[]> {
  const res = await fetch(`${API_URL}/gql`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      query: `
        query Search($q: String!, $locale: String) {
          searchPosts(query: $q, locale: $locale) {
            title
            slug
            excerpt
          }
        }
      `,
      variables: { q: query, locale },
    }),
  });

  if (!res.ok) return [];
  const json = (await res.json()) as { data?: { searchPosts?: PostSummary[] } };
  return json.data?.searchPosts ?? [];
}
