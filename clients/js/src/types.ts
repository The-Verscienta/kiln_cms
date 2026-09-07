/**
 * Shared shapes for the Kiln delivery surfaces.
 *
 * These are the hand-written baseline: enough to consume any Kiln site without
 * codegen. For per-site types — your content types, admin-defined dynamic
 * types, custom fields — generate `kiln-types.d.ts` with the bundled
 * `kiln-types` CLI (see `generator.ts`) and pass those types to the generic
 * client methods instead.
 */

// ── JSON:API (flattened) ────────────────────────────────────────────────────

/** A `{type, id}` resource linkage ref, as flattened from a relationship. */
export interface ResourceRef {
  type: string;
  id: string;
}

/**
 * A flattened JSON:API resource: its `attributes` spread at the top level,
 * plus `id`/`type` and relationships reduced to `{type, id}` ref lists.
 */
export interface Item {
  id: string;
  type: string;
  relationships: Record<string, ResourceRef[]>;
  [attribute: string]: unknown;
}

/** Included resources, keyed by `refKey(type, id)` for O(1) joins. */
export type IncludedMap = Map<string, Item>;

export interface ListResult<T extends Item = Item> {
  items: T[];
  /** Side-loaded resources (`include: [...]`), keyed by `refKey(type, id)`. */
  included: IncludedMap;
  /** `meta.page.total` — `null` when the request disabled counting. */
  total: number | null;
}

// ── filters ─────────────────────────────────────────────────────────────────

export type FilterScalar = string | number | boolean;

/**
 * One filter entry. A scalar is equality; an object nests — either an operator
 * (`{ lte: 10 }`, `{ ilike: "%q%" }`, `{ in: [...] }`) or a relationship
 * filter (`{ slug: "x" }`); an array fans out to `key[]=` params (used under
 * `in`). The encoding is uniform, so operators and relationship paths compose:
 * `{ tags: { slug: { ilike: "%sale%" } } }`.
 */
export type FilterSpec = FilterScalar | FilterScalar[] | { [field: string]: FilterSpec };

/** Field (or relationship) name → filter spec. */
export type Filter = Record<string, FilterSpec>;

// ── options ─────────────────────────────────────────────────────────────────

/** Options accepted by every request: an abort/timeout override. */
export interface RequestOptions {
  /**
   * Abort signal for this request. Overrides the client's default per-request
   * timeout — combine with `AbortSignal.timeout(ms)` to bound a call that must
   * not hang (the semantic routes stall, not fail, when the embedding backend
   * degrades; see the README).
   */
  signal?: AbortSignal;
}

export interface ListOptions extends RequestOptions {
  /** Public attribute filters, encoded as `filter[field]=` / `filter[field][op]=`. */
  filter?: Filter;
  /** Admin-defined custom fields, encoded as `custom_filter[field]=`. */
  customFilter?: Filter;
  /** Sort fields; `-` prefix descends (e.g. `["-published_at", "title"]`). */
  sort?: string[];
  /** Sort on admin-defined custom fields. */
  customSort?: string[];
  /** Relationship paths to side-load (e.g. `["tags", "category"]`). */
  include?: string[];
  /**
   * Sparse fieldsets, `{ post: ["title", "slug"] }`. Also the way to pull
   * public calculations, which are not serialized by default.
   */
  fields?: Record<string, string[]>;
  /** Page size (the server caps it at 100). */
  limit?: number;
  offset?: number;
  /** Ask for `meta.page.total` (default `true`; result `total` is `null` when off). */
  count?: boolean;
  /**
   * Read the server-side state-filtered `/published` feed (default `true`).
   * Pass `false` only for an editor-facing caller that must see drafts —
   * with a bearer key, the plain index widens to whatever the key can see.
   */
  published?: boolean;
}

export interface SearchOptions extends RequestOptions {
  locale?: string;
  /** Match content carrying any of these tag ids (facet argument). */
  tagIds?: string[];
  /** Custom-field facets; compose with the search query. */
  customFilter?: Filter;
  /** Explicit sort overrides relevance (which degrades to the tiebreaker). */
  sort?: string[];
  /** `page[limit]`; the action caps its own maximum. */
  limit?: number;
  include?: string[];
  fields?: Record<string, string[]>;
  /** Search the published-only twin (default `true`). */
  published?: boolean;
}

export interface AutocompleteOptions extends RequestOptions {
  locale?: string;
  /** Published-only by default (the base route would suggest draft titles). */
  published?: boolean;
}

export interface HybridSearchOptions extends RequestOptions {
  /** Server caps at 25. */
  limit?: number;
  locale?: string;
  /** Category slug facet. */
  category?: string;
  /** Include facet counts in the response. */
  facets?: boolean;
}

/** Per-section hybrid search results, as served by `GET /api/search`. */
export interface HybridSearchResult {
  results?: Record<string, unknown[]>;
  facets?: Record<string, unknown>;
  /** "Did you mean" — present on sparse results. */
  suggestion?: string | null;
  [key: string]: unknown;
}

// ── fired artifacts (`/api/content`) ────────────────────────────────────────

export type Surface = "json" | "json_ld" | "web";

export interface ArtifactOptions extends RequestOptions {
  /** `json` (default) — structured blocks; `json_ld` — schema.org graph; `web` — `{html}`. */
  surface?: Surface;
  locale?: string;
  /**
   * Point-in-time read (`?as_of=`): serve the document as it was at that
   * moment. ISO 8601 datetime, or a bare date (end of that day, UTC). 404s:
   * `not_published` (nothing published by then) vs `withdrawn` (unpublished
   * before then and not republished).
   */
  asOf?: string | Date;
  /**
   * A cold cache answers 503; by default the client retries once after
   * `retryDelayMs`. Pass `false` to fail fast.
   */
  retry?: boolean;
  retryDelayMs?: number;
}

/** A Portable Text span — a run of text carrying zero or more `marks`. */
export interface PortableTextSpan {
  _type: "span";
  text: string;
  marks?: string[];
  [key: string]: unknown;
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
  [key: string]: unknown;
}

/**
 * A typed content block as serialized by the `json` surface — the
 * `_type`-discriminated union. This baseline names the built-in block types;
 * the index-signature fallback keeps it forward-compatible with plugin and
 * custom blocks. Generate `kiln-types.d.ts` for the exact per-site union.
 */
export type Block =
  | { _type: "rich_text"; body: PortableTextBlock[]; [key: string]: unknown }
  | { _type: "heading"; text: string; level: number; [key: string]: unknown }
  | {
      _type: "image";
      url: string;
      alt?: string | null;
      caption?: string | null;
      [key: string]: unknown;
    }
  | { _type: "quote"; text: string; citation?: string | null; [key: string]: unknown }
  | { _type: "divider"; [key: string]: unknown }
  | { _type: "embed"; url: string; [key: string]: unknown }
  | { _type: string; [key: string]: unknown };

/** A fired document, as returned by `?surface=json`. */
export interface ArtifactDocument {
  type: string;
  title: string;
  slug: string;
  blocks: Block[];
  [key: string]: unknown;
}

/** `?surface=web` body. */
export interface WebArtifact {
  html: string;
  [key: string]: unknown;
}

// ── point-in-time collection index ──────────────────────────────────────────

export interface AsOfIndexEntry {
  slug: string;
  title: string | null;
  published_at: string | null;
  /**
   * Link to the per-document snapshot — `null` when the document has since
   * been unpublished or renamed (id-addressable history is a later phase).
   */
  href: string | null;
}

export interface AsOfIndexResult {
  as_of: string;
  type: string;
  entries: AsOfIndexEntry[];
}

export interface AsOfIndexOptions extends RequestOptions {
  /** Default 100, max 500. */
  limit?: number;
}
