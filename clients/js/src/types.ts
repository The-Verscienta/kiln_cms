/**
 * Shared shapes for the Kiln delivery surfaces.
 *
 * These are the hand-written baseline: enough to consume any Kiln site without
 * codegen. For per-site types — your content types, admin-defined dynamic
 * types, custom fields — generate `kiln-types.d.ts` with the bundled
 * `kiln-types` CLI (see `generator.ts`) and pass those types to the generic
 * client methods instead.
 */

import type { GraphQLErrorObject } from "./errors.js";

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
  /**
   * Admin-defined custom fields, encoded as `custom_filter[field]=`. The server
   * also accepts a custom field's bare name in `filter` (`filter[price]`) when
   * no built-in attribute has that name, but `customFilter` is the stable
   * form: a later built-in with the same name would shadow `filter[price]`.
   * The client keeps emitting `custom_filter` for custom fields.
   */
  customFilter?: Filter;
  /** Sort fields; `-` prefix descends (e.g. `["-published_at", "title"]`). */
  sort?: string[];
  /**
   * Sort on admin-defined custom fields (`custom_sort`). The server also
   * accepts a custom name in `sort` (`sort=-price`) provided custom names come
   * last, but `customSort` is the stable form and has no ordering rule.
   */
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
  /**
   * Custom-field facets (`custom_filter[...]`); compose with the search query.
   * Prefer this over a bare custom name in `filter`; it is the stable form.
   */
  customFilter?: Filter;
  /** Explicit sort overrides relevance (which degrades to the tiebreaker). */
  sort?: string[];
  /**
   * Sort on admin-defined custom fields (`custom_sort`, e.g. `["price",
   * "-rating"]`). Precedence: `sort`, then `customSort`, then relevance. On
   * semantic search a leading custom sort replaces distance ordering, so the
   * vector index no longer serves the order (same as built-in `sort`). Not
   * accepted by `autocomplete`.
   */
  customSort?: string[];
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

export interface SchemaOptions extends RequestOptions {
  /** Restrict the document to these content types (`?type=post,page`). */
  types?: string[];
  /** The block union alone, no content types and no database read. */
  blocksOnly?: boolean;
}

/**
 * The delivery schema as OpenAPI 3.1 components, from
 * `GET /api/schema?format=openapi`. The same schemas `schema()` returns, with
 * `$defs` moved to `components.schemas` (and every `$ref` with them), the
 * document union as `components.schemas.document`, and an explicit `_type`
 * mapping on the block union's discriminator. Schema objects are JSON Schema
 * 2020-12. No `paths`: it describes payloads, not routes.
 */
export interface OpenApiComponentsDocument {
  openapi: string;
  /** `version` is the fired-artifact format version, not the app version. */
  info: { title: string; version: string; description?: string; [key: string]: unknown };
  jsonSchemaDialect?: string;
  components: { schemas: Record<string, Record<string, unknown>> };
  "x-kiln"?: { artifact_format_version?: unknown; [key: string]: unknown };
  [keyword: string]: unknown;
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

/**
 * A freshly minted draft preview link (`POST /api/content/:type/:id/preview-token`).
 * Hand `token` (or `url`) to the browser — never the API key that minted it.
 */
export interface MintedPreview {
  /** Signed, read-only, this document only. Redeem with `preview(token)`. */
  token: string;
  /** The shareable link, on the host of the site that owns the document. */
  url: string;
  type: string;
  id: string;
  /** ISO 8601. */
  expires_at: string;
  /** Seconds (900). */
  expires_in: number;
}

export interface AsOfIndexOptions extends RequestOptions {
  /** Default 100, max 500. */
  limit?: number;
}

// ── headless routing and site structure ─────────────────────────────────────

/**
 * The locale parameters every locale-aware delivery surface reads
 * (`?locale=`, `?fallback=`, `?fallback_locale=`). A locale the site does not
 * run is a `KilnValidationError` (`unsupported_locale`).
 */
export interface DeliveryLocaleOptions extends RequestOptions {
  locale?: string;
  /** `false` turns the site's fallback chain off: only `locale` itself answers. */
  fallback?: boolean;
  /** Fall back to this locale rather than along the site's configured chain. */
  fallbackLocale?: string;
}

/** Published content lives at the path, found in `locale`. */
export interface ResolveFound {
  status: "ok";
  type: string;
  slug: string;
  id: string;
  path: string;
  locale: string;
}

/** A pathauto redirect: answer the visitor with a 301 to `to`. */
export interface ResolveMoved {
  status: "moved";
  to: string;
  type: string;
  slug: string;
  id: string;
}

/** Nothing lives at the path. The server says so with a 404. */
export interface ResolveNotFound {
  status: "not_found";
}

/** `GET /api/resolve`'s verdict on a path. Branch on `status`. */
export type ResolveResult = ResolveFound | ResolveMoved | ResolveNotFound;

export interface MenuSummary {
  key: string;
  name: string;
  locale: string;
}

export interface MenuList {
  menus: MenuSummary[];
}

export interface MenuNode {
  id: string;
  label: string;
  /**
   * A content item's current published path, an external link's URL, or
   * `null` for a heading (`link_type: "none"`).
   */
  url: string | null;
  link_type: "content" | "url" | "none";
  open_in_new_tab: boolean;
  children: MenuNode[];
}

/** One resolved menu. `locale` names the variant served. */
export interface Menu {
  key: string;
  name: string;
  locale: string;
  items: MenuNode[];
}

export interface Locales {
  default: string;
  locales: string[];
  /** Each locale's fallback chain, itself excluded; `[]` never falls back. */
  fallbacks: Record<string, string[]>;
}

export interface RelatedOptions extends DeliveryLocaleOptions {
  /** Default 5, max 20. */
  limit?: number;
}

export interface RelatedDocument {
  type: string;
  slug: string;
  title: string | null;
  /** Higher is closer. */
  score: number;
  /** The related document's artifact, `/api/content/:type/:slug`. */
  href: string;
}

export interface RelatedResult {
  type: string;
  slug: string;
  locale: string;
  /** Empty when semantic search is off. */
  related: RelatedDocument[];
}

// ── forms ───────────────────────────────────────────────────────────────────

export interface FormField {
  name: string;
  label: string;
  type: "string" | "text" | "email" | "integer" | "boolean" | "date" | "select";
  required: boolean;
  /** A `select` field's choices; `[]` for every other type. */
  options: string[];
  help_text: string | null;
  placeholder: string | null;
  default_value: string | null;
  width: "full" | "half" | "third";
}

/** An admin-defined form, as `GET /api/forms/:slug` describes it. */
export interface FormSchema {
  slug: string;
  name: string;
  description: string | null;
  success_message: string | null;
  submit_label: string | null;
  /** Render this as a hidden, empty input, and relay it untouched. */
  honeypot_field: string;
  /** The form-encoded browser route; `submitForm` posts JSON to `/api/forms/:slug`. */
  submit_url: string;
  fields: FormField[];
  /**
   * The human-verification check this form asks for, or `null` (absent from
   * older servers). When present, draw the provider's widget
   * and send its token as `field`; a submission without one is accepted but
   * held for review.
   */
  challenge?: FormChallenge | null;
}

/** What a front end needs to draw a form's human-verification widget. */
export interface FormChallenge {
  required: true;
  /** The provider's id, e.g. `"turnstile"`. */
  provider: string;
  site_key: string;
  /** The provider's script, for explicit rendering. */
  script_url: string;
  /**
   * The action the widget must be drawn for. Pass it to `render` under
   * `action_option`; when that is `null` the widget takes no action.
   */
  action: string;
  /** The browser global the script defines (absent from older servers). */
  global?: string;
  /**
   * When not `null`, the script reports readiness by calling a global
   * function named by this query parameter (reCAPTCHA's `onload`): wait for
   * it rather than the script's `load` event. Absent from older servers.
   */
  onload_param?: string | null;
  /** Extra options to pass `render` (absent from older servers). */
  render_options?: Record<string, unknown>;
  /** The `render` option the action goes under, or `null` for none. */
  action_option?: string | null;
  /** Whether people normally have to click or solve something. */
  interactive?: boolean;
  /** The browser API the global offers; today always `"explicit_render"`. */
  api?: "explicit_render";
  /** The value name the token is submitted under: `_kiln_challenge`. */
  field: string;
  /** What happens to a submission sent without a token. */
  without_token: "held";
}

export interface SubmitFormOptions extends RequestOptions {
  /** Recorded on the submission. */
  locale?: string;
}

export interface FormSubmitResult {
  ok: true;
  message: string | null;
  /**
   * Present only when the form asks for a human-verification check:
   * `"verified"`, or `"held"` when the submission was kept for review
   * instead of being acted on (no token, a token solved on a host the
   * server does not accept, or a provider it could not reach). A token the
   * provider refused is a `KilnValidationError` naming `_kiln_challenge`.
   */
  challenge?: "verified" | "held";
}

// ── sync (delta) API ────────────────────────────────────────────────────────

/**
 * A document an anonymous reader can fetch right now, with its fired artifact
 * (the same body `artifact()` returns for that surface). Replace your copy.
 */
export interface SyncUpsert<A = ArtifactDocument> {
  op: "upsert";
  type: string;
  id: string;
  slug: string;
  locale: string;
  published_at: string | null;
  updated_at: string;
  artifact: A;
}

/**
 * A document you were given earlier that is no longer publicly readable —
 * unpublished, archived, deleted, locked or moved to a members-only audience.
 * Remove your copy. Carries no reason, slug or body, by design.
 */
export interface SyncDelete {
  op: "delete";
  type: string;
  id: string;
}

export type SyncItem<A = ArtifactDocument> = SyncUpsert<A> | SyncDelete;

/** One page of `GET /api/sync`. */
export interface SyncPage<A = ArtifactDocument> {
  items: SyncItem<A>[];
  /** Opaque; follow it now while `has_more`, store it once it is false. */
  cursor: string;
  has_more: boolean;
}

export interface SyncStartOptions extends RequestOptions {
  /** Restrict the sync to one content type (singular, e.g. `"post"`). */
  type?: string;
  /** Artifact surface embedded in each upsert (default `json`). */
  surface?: Surface;
  /** Items per page (default 100, max 500). */
  limit?: number;
}

export interface SyncOptions extends SyncStartOptions {
  /**
   * Resume from a stored cursor. Omit to start with a full snapshot
   * (`initial=true`). `type`/`surface` are fixed by the cursor.
   */
  cursor?: string;
  /**
   * A page holding a just-published document can answer 503 while its
   * artifact compiles; `sync()` waits `retryDelayMs` (default 2000) and asks
   * again, up to `retries` times per page (default 3).
   */
  retries?: number;
  retryDelayMs?: number;
}

export interface SyncResult<A = ArtifactDocument> {
  /** Every item across every page, in order — apply them in this order. */
  items: SyncItem<A>[];
  /** Store this and pass it as `cursor` next time. */
  cursor: string;
}

// ── media uploads ───────────────────────────────────────────────────────────

/**
 * A media library item, flattened like any other resource. The attributes
 * below are the ones every item carries; `kind` and `processing` come back on
 * upload responses only (see `KilnClient.uploadMedia`).
 */
export interface MediaItem extends Item {
  filename: string;
  content_type: string | null;
  byte_size: number | null;
  width: number | null;
  height: number | null;
  duration_seconds: number | null;
  url: string | null;
  alt: string | null;
  caption: string | null;
  decorative: boolean;
  focal_x: number;
  focal_y: number;
  variants: Record<string, unknown>;
  uploaded_by_id: string | null;
  /** Upload responses only: what the server's byte-sniffing decided. */
  kind?: "image" | "video" | "audio" | "captions" | "document";
  /**
   * Upload responses only: `true` while an A/V upload's metadata strip is
   * still pending — the item exists, but its `url` serves nothing yet.
   */
  processing?: boolean;
}

/** Metadata settable on upload (and afterwards via `updateMedia`). */
export interface MediaMetadata {
  alt?: string;
  caption?: string;
  /** A decorative image correctly has no alt text (`alt=""`). */
  decorative?: boolean;
  /** Focal point for smart crops, 0.0–1.0 from the left. */
  focalX?: number;
  /** Focal point for smart crops, 0.0–1.0 from the top. */
  focalY?: number;
  /** Complete tag set (ids of tags on this site). */
  tagIds?: string[];
}

export interface UploadMediaOptions extends MediaMetadata, RequestOptions {
  /** Name to record. Default: the `File`'s own name, else `"upload"`. */
  filename?: string;
}

export interface ImportMediaOptions extends MediaMetadata, RequestOptions {
  /** Name to record instead of the one the URL's path implies. */
  filename?: string;
}

/** `updateMedia` changes. Tags follow content's replace / merge verbs. */
export interface MediaMetadataUpdate extends Omit<MediaMetadata, "tagIds"> {
  /** Replaces the whole tag set. Don't combine with add/remove. */
  tagIds?: string[];
  addTagIds?: string[];
  removeTagIds?: string[];
}

/** An issued direct upload: PUT the bytes to `uploadUrl`, then complete. */
export interface DirectUpload {
  token: string;
  uploadUrl: string;
  method: "PUT";
  /** Signed headers — send them exactly as given (`content-length` among them). */
  headers: Record<string, string>;
  expiresAt: string;
  maxBytes: number;
}
// ── editorial reads (editor-tier credential) ────────────────────────────────

export interface RevisionListOptions extends RequestOptions {
  /** Page size, 1–100 (server default 20; an out-of-range value gets the default). */
  limit?: number;
  /** Opaque keyset cursor — the previous page's `meta.next_cursor`. */
  cursor?: string;
}

/**
 * One entry of a document's version history. Carries the *names* of the
 * editorial fields the write changed, never their values; the acting user is
 * an id only (`null` for a system write).
 */
export interface Revision {
  id: string;
  /** The action that wrote it: `create`, `update`, `autosave`, `publish`, `restore_version`, … */
  action: string;
  action_type: "create" | "update" | "destroy";
  inserted_at: string;
  user_id: string | null;
  changed_fields: string[];
}

/** `GET /api/content/:type/:id/revisions`, as served. */
export interface RevisionList {
  data: Revision[];
  meta: {
    limit: number;
    /** Pass back as `cursor` for the next (older) page; `null` on the last. */
    next_cursor: string | null;
  };
}

/**
 * One revision with its values: the version's own raw `changes`, and the
 * full `snapshot` of the document at that revision (folded from every
 * version up to it). Values are in their stored JSON shape.
 */
export interface RevisionDetail extends Revision {
  /** Sorted keys of the custom fields this write changed (diff against the last revision that carried `custom_fields`). */
  changed_custom_fields: string[];
  changes: Record<string, unknown>;
  snapshot: Record<string, unknown>;
}

/** The result of restoring a revision — the restore is itself a new revision. */
export interface RestoreResult {
  id: string;
  type: string;
  state: string;
  restored_version_id: string;
  revision: Revision;
}

/** A content release (`/api/json/releases`), flattened. */
export interface ContentRelease extends Item {
  name: string;
  description: string | null;
  state:
    | "open"
    | "scheduled"
    | "publishing"
    | "published"
    | "failed"
    | "rolling_back"
    | "rolled_back"
    | "archived";
  scheduled_at: string | null;
  published_at: string | null;
  rolled_back_at: string | null;
  failure_reason: string | null;
  failed_item_id: string | null;
}

/** One pending change inside a release (`/api/json/release-items`), flattened. */
export interface ContentReleaseItem extends Item {
  release_id: string;
  /** The document's content type name, and its id — resolve through that type's own route. */
  content_type: string;
  content_id: string;
  action: "publish" | "unpublish";
  status: "pending" | "applied" | "skipped" | "cancelled" | "rolled_back";
  prior_state: string | null;
  prior_version_id: string | null;
  applied_at: string | null;
}

/** Options for the release index — the JSON:API list options, minus the `/published` switch. */
export type ReleaseListOptions = Omit<ListOptions, "published" | "customFilter" | "customSort">;

export interface ReleaseOptions extends RequestOptions {
  /** Side-load relationships — `["items"]` for the release's contents. */
  include?: string[];
  fields?: Record<string, string[]>;
}

// ── writes (the JSON:API write surface, #330) ───────────────────────────────

/**
 * The workflow transitions the JSON:API routes as `PATCH /:plural/:id/<verb>`,
 * by their Ash action names. `submit_for_review` needs an editor-or-above key;
 * the other three are admin-only. Any other string passes through (kebab-cased
 * into the route), so a verb a newer server adds is reachable before this list
 * learns it.
 */
export type WorkflowVerb =
  "submit_for_review" | "return_to_draft" | "publish" | "unpublish" | (string & {});

export interface WriteOptions extends RequestOptions {
  /**
   * The JSON:API resource `type` sent as `data.type` — the singular type name
   * the server validates against (`"post"`, `"page"`, `"entry"`). Derived from
   * the plural route (`entries` → `entry`, `posts` → `post`); pass it for a
   * content type whose plural is irregular (`people` → `"person"`).
   */
  type?: string;
}

/** Options for `create()`: a write, plus who a draft is for. */
export interface CreateOptions extends WriteOptions {
  /**
   * Sent as the `X-Kiln-On-Behalf-Of` header: an opaque label (typically your
   * own user id) that Kiln stores on a draft created with a `:draft_write`
   * API key, beside the key's id and name, so a reviewer sees who it was for
   * (kiln_cms#2273; a server newer than 1.8). Stored only, never
   * authorization; any other key's request ignores it. Omitted or `undefined`
   * sends no header.
   */
  onBehalfOf?: string;
}

/**
 * The provenance attributes Kiln records on content created with a
 * `:draft_write` API key (kiln_cms#2273). They are returned only to an
 * editor, an admin, or the key that created the record; every other reader's
 * response simply lacks them, so each is optional. `null` on a record no
 * `:draft_write` key created. Intersect with `Item`:
 * `writer.create<Item & ContentProvenance>(…)`.
 */
export interface ContentProvenance {
  /** The id of the `:draft_write` key that created the record. */
  created_via_key_id?: string | null;
  /** That key's name when it created the record. */
  created_via_key_name?: string | null;
  /** The `X-Kiln-On-Behalf-Of` label sent on the create, if any. */
  on_behalf_of?: string | null;
}

// ── GraphQL ─────────────────────────────────────────────────────────────────

export interface GraphQLOptions extends RequestOptions {
  /** Which operation to run when `query` defines several. */
  operationName?: string;
}

/** A `POST /gql` response body. */
export interface GraphQLResponse<TData> {
  data?: TData | null;
  errors?: GraphQLErrorObject[];
}
