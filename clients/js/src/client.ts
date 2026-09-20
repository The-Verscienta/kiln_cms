/**
 * Typed client for the KilnCMS APIs — the JSON:API read surface at
 * `/api/json/*`, per-type and hybrid search, fired artifacts at
 * `/api/content/:type/:slug` (including `?as_of=` point-in-time reads),
 * preview tokens — minting and redeeming them — the JSON:API write surface
 * (create, update, workflow transitions, soft-delete) and a minimal `/gql`
 * helper (see Kiln's `docs/json-api.md` and `docs/headless-consumer-guide.md`).
 *
 * A port of the official Elixir client (`clients/elixir/kiln_client`), which
 * encodes the safe defaults so consumers don't rediscover the traps one
 * incident at a time.
 *
 * ## Published-only by default
 *
 * Reads are published-only by default. Do not rely on the credential for
 * that: Kiln's read policy authorizes any `:editor` actor for every workflow
 * state (and admins bypass it outright), so an API key minted on a staff
 * account would otherwise see drafts through the plain index and the base
 * search routes (kiln_cms#297). This client reads the server-side filtered
 * surfaces instead — the `/published` feed and the `/search/published`,
 * `/semantic-search/published`, `/autocomplete/published` twins — whose
 * `state == :published` filter holds whatever identity the key carries.
 * Callers that genuinely need drafts must opt out per call with
 * `published: false`.
 *
 * ## Writes need a key, and a different one
 *
 * The write methods (`create`, `update`, `transition` and its wrappers,
 * `delete`) drive the JSON:API write surface (Kiln's `docs/json-api.md` →
 * "Writing"). They refuse to send anything without an `apiKey` — throwing
 * `KilnConfigError` before a request leaves the process — because an
 * anonymous write can only ever be a 401/403. The key must be a `:read_write`
 * key: editor-or-above to create, update and submit for review, admin to
 * return to draft, publish, unpublish and delete. That is the opposite of
 * the `:viewer` key delivery reads want, so a site that both reads and writes
 * should hold two clients rather than one widened key.
 */

import {
  type GraphQLErrorObject,
  KilnConfigError,
  KilnError,
  KilnGraphQLError,
  KilnHttpError,
  KilnNetworkError,
  httpError,
  parseRetryAfter,
} from "./errors.js";
import type { SchemaDocument } from "./generator.js";
import {
  appendArray,
  appendFilter,
  appendIfPresent,
  appendSparseFields,
  flattenDocument,
  listParams,
} from "./jsonapi.js";
import type {
  ArtifactDocument,
  ArtifactOptions,
  AsOfIndexOptions,
  AsOfIndexResult,
  AutocompleteOptions,
  Filter,
  GraphQLOptions,
  GraphQLResponse,
  HybridSearchOptions,
  HybridSearchResult,
  Item,
  ListOptions,
  ListResult,
  MintedPreview,
  RequestOptions,
  SchemaOptions,
  SearchOptions,
  WorkflowVerb,
  WriteOptions,
} from "./types.js";

const JSON_API = "application/vnd.api+json";

// The server accepts a larger `page[limit]` but returns only the first 100
// rows, so batched reads must chunk at this bound to stay lossless.
const MAX_PAGE_SIZE = 100;

export interface KilnClientOptions {
  /** Base URL of the Kiln instance, e.g. `https://cms.example.com`. */
  baseUrl: string;
  /**
   * Bearer API key (`kiln_…`). Optional for reads — mint delivery keys on a
   * `:viewer` account, since an editor/admin key widens what the
   * credential-sensitive routes return (see the module doc and Kiln's
   * `docs/api.md` → "API keys"). **Required** for the write methods, which
   * need a `:read_write` key on an editor or admin account. The client sends
   * it only as the `Authorization` header and never puts it in an error.
   */
  apiKey?: string;
  /**
   * Fetch implementation (default `globalThis.fetch`). The test seam: pass a
   * stub and the client is fully testable without a running Kiln.
   */
  fetch?: typeof globalThis.fetch;
  /**
   * Per-request timeout in milliseconds (default 15000), applied when a call
   * passes no `signal` of its own. The semantic routes stall rather than fail
   * when the embedding backend degrades (measured at ~70s on an instance that
   * still answered 200), so callers with a keyword fallback should bound those
   * calls well above their healthy latency.
   */
  timeoutMs?: number;
  /** Extra headers merged into every request. */
  headers?: Record<string, string>;
}

export function createClient(options: KilnClientOptions): KilnClient {
  return new KilnClient(options);
}

export class KilnClient {
  readonly baseUrl: string;
  private readonly apiKey?: string;
  private readonly fetchImpl: typeof globalThis.fetch;
  private readonly timeoutMs: number;
  private readonly headers: Record<string, string>;

  constructor(options: KilnClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.apiKey = options.apiKey;
    this.fetchImpl = options.fetch ?? globalThis.fetch;
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.headers = options.headers ?? {};
  }

  // ── JSON:API content reads ────────────────────────────────────────────────

  /**
   * List records of a content type (plural route name, e.g. `"posts"`;
   * dynamic types go through `"entries"` with a `type_name` filter):
   *
   *     const { items, total } = await kiln.list("posts", {
   *       filter: { tags: { slug: "news" } },
   *       sort: ["-published_at"],
   *       include: ["tags"],
   *       limit: 10,
   *     });
   */
  async list<T extends Item = Item>(
    plural: string,
    options: ListOptions = {},
  ): Promise<ListResult<T>> {
    const path = published(options) ? `/api/json/${plural}/published` : `/api/json/${plural}`;
    const doc = await this.request(path, listParams(options), options.signal);
    return flattenDocument<T>(doc);
  }

  /**
   * Fetch the first record matching `filter`, or `null`. The included lookup
   * rides along on the result so detail callers get their joins in one value.
   */
  async one<T extends Item = Item>(
    plural: string,
    filter: Filter,
    options: ListOptions = {},
  ): Promise<(T & { included: ListResult<T>["included"] }) | null> {
    const { items, included } = await this.list<T>(plural, {
      ...options,
      filter,
      limit: 1,
      count: false,
    });
    const item = items[0];
    return item === undefined ? null : { ...item, included };
  }

  /**
   * Fetch records by id list (`filter[id][in]=`). Returns the items in `ids`
   * order; ids that resolve to nothing are dropped. The server clamps
   * `page[limit]` at 100, so longer id lists are fetched in parallel
   * 100-id chunks — without that, records past the clamp would be silently
   * indistinguishable from misses.
   */
  async byIds<T extends Item = Item>(
    plural: string,
    ids: string[],
    options: ListOptions = {},
  ): Promise<T[]> {
    if (ids.length === 0) return [];

    const chunks: string[][] = [];
    for (let start = 0; start < ids.length; start += MAX_PAGE_SIZE) {
      chunks.push(ids.slice(start, start + MAX_PAGE_SIZE));
    }

    const results = await Promise.all(
      chunks.map((chunk) =>
        this.list<T>(plural, {
          ...options,
          filter: { ...options.filter, id: { in: chunk } },
          limit: chunk.length,
          count: false,
        }),
      ),
    );

    const byId = new Map(
      results.flatMap((result) => result.items).map((item) => [item.id, item]),
    );
    return ids.map((id) => byId.get(id)).filter((item): item is T => item !== undefined);
  }

  // ── per-type search ───────────────────────────────────────────────────────

  /**
   * Per-type full-text search: `GET /api/json/:plural/search[/published]`.
   * Relevance-ranked; returns a plain (unpaginated) list — the action caps its
   * own result size — so `total` is always `null`.
   */
  textSearch<T extends Item = Item>(
    plural: string,
    query: string,
    options: SearchOptions = {},
  ): Promise<ListResult<T>> {
    return this.searchRequest(plural, "search", { query }, options);
  }

  /**
   * Per-type semantic (vector) search:
   * `GET /api/json/:plural/semantic-search[/published]`. Ordered by cosine
   * distance; degrades to an empty result set when the server has no
   * embeddings. If you have a keyword fallback, bound this call with
   * `signal: AbortSignal.timeout(ms)` — a degraded embedding backend stalls
   * rather than fails.
   */
  semanticSearch<T extends Item = Item>(
    plural: string,
    query: string,
    options: SearchOptions = {},
  ): Promise<ListResult<T>> {
    return this.searchRequest(plural, "semantic-search", { query }, options);
  }

  /**
   * Typo-tolerant title autocomplete:
   * `GET /api/json/:plural/autocomplete[/published]?prefix=…`. At most 10
   * suggestions, best match first.
   */
  autocomplete<T extends Item = Item>(
    plural: string,
    prefix: string,
    options: AutocompleteOptions = {},
  ): Promise<ListResult<T>> {
    return this.searchRequest(plural, "autocomplete", { prefix }, options);
  }

  private async searchRequest<T extends Item>(
    plural: string,
    route: string,
    baseParams: Record<string, string>,
    options: SearchOptions,
  ): Promise<ListResult<T>> {
    const path = published(options)
      ? `/api/json/${plural}/${route}/published`
      : `/api/json/${plural}/${route}`;

    const params = new URLSearchParams(baseParams);
    appendIfPresent(params, "locale", options.locale);
    appendArray(params, "tag_ids", options.tagIds);
    if (options.customFilter) appendFilter(params, "custom_filter", options.customFilter);
    appendIfPresent(params, "sort", options.sort?.join(","));
    appendIfPresent(params, "page[limit]", options.limit);
    appendIfPresent(params, "include", options.include?.join(","));
    appendSparseFields(params, options.fields);

    const doc = await this.request(path, params, options.signal);
    return flattenDocument<T>(doc);
  }

  // ── other delivery surfaces ───────────────────────────────────────────────

  /**
   * Hybrid (keyword + semantic) search at `/api/search`. Returns the raw
   * response — sections under `results` (`pages`, `posts`, `entries`,
   * `categories`, `tags`, `tag_groups`), plus `facets` when requested, and a
   * `suggestion` ("did you mean") on sparse results.
   *
   * **Visibility follows the credential**: this endpoint has no published-only
   * variant — anonymous calls match published content only, but a bearer key
   * widens it to whatever the minting account can see. Mint delivery keys on
   * a `:viewer` account.
   */
  async search(q: string, options: HybridSearchOptions = {}): Promise<HybridSearchResult> {
    const params = new URLSearchParams({ q });
    appendIfPresent(params, "limit", options.limit);
    appendIfPresent(params, "locale", options.locale);
    appendIfPresent(params, "category", options.category);
    if (options.facets) params.append("facets", "true");
    return (await this.request("/api/search", params, options.signal)) as HybridSearchResult;
  }

  /**
   * Fired artifact for a published record: pre-rendered content at
   * `GET /api/content/:type/:slug` (singular type name, e.g. `"post"`).
   *
   * Pass `asOf` for a point-in-time read — the document as it was at that
   * moment, reconstructed from version history. Throws `KilnHttpError` with
   * status 404 for an unknown slug (`not_published` / `withdrawn` for `asOf`
   * reads); a cold cache answers 503, retried once after `retryDelayMs`
   * (default 2000) unless `retry: false`.
   */
  async artifact<T = ArtifactDocument>(
    type: string,
    slug: string,
    options: ArtifactOptions = {},
  ): Promise<T> {
    const params = new URLSearchParams();
    appendIfPresent(params, "surface", options.surface);
    appendIfPresent(params, "locale", options.locale);
    if (options.asOf !== undefined) params.append("as_of", asOfParam(options.asOf));

    const path = `/api/content/${encodeURIComponent(type)}/${encodeURIComponent(slug)}`;

    try {
      return (await this.request(path, params, options.signal, "application/json")) as T;
    } catch (error) {
      const retriable =
        error instanceof KilnHttpError && error.status === 503 && options.retry !== false;
      if (!retriable) throw error;
      // The wait races the caller's signal: a bounded call must not overrun
      // its bound sleeping, and once it has aborted, the 503 we already hold
      // is the informative error — not the AbortError a doomed retry would
      // surface.
      try {
        await sleep(options.retryDelayMs ?? 2_000, options.signal);
      } catch {
        throw error;
      }
      return (await this.request(path, params, options.signal, "application/json")) as T;
    }
  }

  /**
   * Point-in-time collection index: `GET /api/content/:type?as_of=` — what was
   * published on this site at that moment. Entries carry `slug`, `title`,
   * `published_at`, and an `href` to the per-document snapshot (`null` when the
   * document was since unpublished or renamed). Unlike the single-document
   * read, the index respects unpublish.
   */
  async contentAsOf(
    type: string,
    asOf: string | Date,
    options: AsOfIndexOptions = {},
  ): Promise<AsOfIndexResult> {
    const params = new URLSearchParams({ as_of: asOfParam(asOf) });
    appendIfPresent(params, "limit", options.limit);
    const path = `/api/content/${encodeURIComponent(type)}`;
    return (await this.request(
      path,
      params,
      options.signal,
      "application/json",
    )) as AsOfIndexResult;
  }

  /**
   * Redeem a preview token: `GET /preview/:token` returns one unpublished
   * draft as JSON (curated public fields, raw editable block tree). Tokens are
   * signed, expire after 15 minutes, and are bound to the site that minted
   * them — an expired or foreign token throws `KilnHttpError`.
   */
  async preview<T = Record<string, unknown>>(
    token: string,
    options: RequestOptions = {},
  ): Promise<T> {
    const path = `/preview/${encodeURIComponent(token)}`;
    const body = await this.request(
      path,
      new URLSearchParams(),
      options.signal,
      "application/json",
    );
    // The server wraps the draft in a `{data: …}` envelope; unwrap it so the
    // caller's type parameter describes the draft itself.
    if (body !== null && typeof body === "object" && "data" in body) {
      return (body as { data: T }).data;
    }
    return body as T;
  }

  /**
   * Mint a draft preview link: `POST /api/content/:type/:id/preview-token`.
   * The server half of a front end's draft mode — call it where the API key
   * lives, then pass the returned `token` to the browser, which redeems it with
   * `preview(token)` and holds no credential of its own. Needs a key (or
   * bearer token) whose owner sees this document's drafts as an editor; a
   * `:read` key is enough. Refusals throw `KilnHttpError` (401 no credential,
   * 403 not an editor of it, 404 unknown document).
   */
  async mintPreview(
    type: string,
    id: string,
    options: RequestOptions = {},
  ): Promise<MintedPreview> {
    const path = `/api/content/${encodeURIComponent(type)}/${encodeURIComponent(id)}/preview-token`;
    return (await this.request(
      path,
      new URLSearchParams(),
      options.signal,
      "application/json",
      "POST",
    )) as MintedPreview;
  }

  /**
   * The site's live delivery schema: `GET /api/schema` — a JSON Schema of the
   * `:json` fired-artifact shape, dynamic content types and custom fields
   * included. Feed it to `emitTypes` (or the `kiln-types` CLI) for per-site
   * TypeScript declarations. `types` restricts to those content types;
   * `blocksOnly` returns the block union alone (no database read).
   */
  async schema(options: SchemaOptions = {}): Promise<SchemaDocument> {
    const params = new URLSearchParams();
    appendIfPresent(params, "type", options.types?.join(","));
    if (options.blocksOnly) params.append("blocks", "only");
    return (await this.request(
      "/api/schema",
      params,
      options.signal,
      "application/json",
    )) as SchemaDocument;
  }

  // ── JSON:API writes (#330) ────────────────────────────────────────────────

  /**
   * Create a record: `POST /api/json/:plural`. Content is always created as a
   * **draft**, attributed to the key's owner; publishing is a separate,
   * admin-only `publish()`. Body content goes in `block_tree` (an array of
   * block maps) or `body_markdown` — never both. Relationship arrays
   * (`tag_ids`, `related_post_ids`) and `category_id` are plain attributes.
   * A dynamic-type entry needs `type_definition_id` (look it up with
   * `kiln.one("type-definitions", { name: "product" })`).
   *
   *     const post = await writer.create("posts", {
   *       title: "Written over the API",
   *       slug: "hello-api",
   *       body_markdown: "# Hello\n\nFrom the SDK.",
   *     });
   *
   * Resolves to the created record, flattened like a read.
   */
  async create<T extends Item = Item>(
    plural: string,
    attributes: Record<string, unknown>,
    options: WriteOptions = {},
  ): Promise<T> {
    // No `id`: the create schema is `additionalProperties: false`, so a
    // client-chosen id is a 400, not a hint.
    const body = { data: { type: resourceType(plural, options), attributes } };
    const doc = await this.write("POST", `/api/json/${plural}`, body, options.signal);
    return onlyItem<T>(doc);
  }

  /**
   * Edit a record: `PATCH /api/json/:plural/:id`. Only the attributes you send
   * change — omit `block_tree` and the body is untouched; `[]` clears it.
   * Editing already-published content re-fires its artifacts, so the live
   * site never serves a stale render.
   *
   * `tag_ids` **replaces** the whole tag set (a partial list detaches the
   * rest); send `add_tag_ids` / `remove_tag_ids` to merge instead — not both
   * styles in one call (a 400). When rewriting a body, echo each block's
   * `_id` (read them via `fields: { post: ["block_ids"] }`) so the server can
   * tell an edit from a replacement.
   */
  async update<T extends Item = Item>(
    plural: string,
    id: string,
    attributes: Record<string, unknown>,
    options: WriteOptions = {},
  ): Promise<T> {
    const body = { data: { type: resourceType(plural, options), id, attributes } };
    const doc = await this.write(
      "PATCH",
      `/api/json/${plural}/${encodeURIComponent(id)}`,
      body,
      options.signal,
    );
    return onlyItem<T>(doc);
  }

  /**
   * Run a workflow transition: `PATCH /api/json/:plural/:id/<verb>` with the
   * empty resource object the routes take. A transition from the wrong state
   * throws `KilnConflictError` (`code: "invalid_state_transition"`, the actual
   * state in `currentState`); a key whose owner lacks the right throws
   * `KilnAuthError` (403). Resolves to the record in its new state.
   */
  async transition<T extends Item = Item>(
    plural: string,
    id: string,
    verb: WorkflowVerb,
    options: WriteOptions = {},
  ): Promise<T> {
    const route = encodeURIComponent(verb.replace(/_/g, "-"));
    const body = { data: { type: resourceType(plural, options), id, attributes: {} } };
    const doc = await this.write(
      "PATCH",
      `/api/json/${plural}/${encodeURIComponent(id)}/${route}`,
      body,
      options.signal,
    );
    return onlyItem<T>(doc);
  }

  /** draft → in_review. Editor-or-above `:read_write` key. */
  submitForReview<T extends Item = Item>(
    plural: string,
    id: string,
    options: WriteOptions = {},
  ): Promise<T> {
    return this.transition<T>(plural, id, "submit_for_review", options);
  }

  /** in_review → draft — the reviewer's "send it back". Admin key. */
  returnToDraft<T extends Item = Item>(
    plural: string,
    id: string,
    options: WriteOptions = {},
  ): Promise<T> {
    return this.transition<T>(plural, id, "return_to_draft", options);
  }

  /** Publish and fire the record's artifacts. Admin key. */
  publish<T extends Item = Item>(
    plural: string,
    id: string,
    options: WriteOptions = {},
  ): Promise<T> {
    return this.transition<T>(plural, id, "publish", options);
  }

  /** Take published content down and purge its artifacts. Admin key. */
  unpublish<T extends Item = Item>(
    plural: string,
    id: string,
    options: WriteOptions = {},
  ): Promise<T> {
    return this.transition<T>(plural, id, "unpublish", options);
  }

  /**
   * Soft-delete a record: `DELETE /api/json/:plural/:id`. Reversible — the
   * record moves to the trash, restorable from the editor. Admin key. There is
   * no hard delete over the API, by design.
   */
  async delete(plural: string, id: string, options: RequestOptions = {}): Promise<void> {
    await this.write(
      "DELETE",
      `/api/json/${plural}/${encodeURIComponent(id)}`,
      undefined,
      options.signal,
    );
  }

  // ── GraphQL ───────────────────────────────────────────────────────────────

  /**
   * Run a GraphQL operation: `POST /gql`. Resolves to `data`; a response
   * carrying a top-level `errors` array throws `KilnGraphQLError` (with any
   * partial `data` on it). Sends the API key when one is configured but does
   * not require one — the published-content queries are anonymous.
   *
   *     const { postBySlug } = await kiln.graphql<{ postBySlug: { title: string } }>(
   *       `query ($slug: String!, $locale: String!) { postBySlug(slug: $slug, locale: $locale) { title } }`,
   *       { slug: "hello-world", locale: "en" },
   *     );
   *
   * Ash mutations report a refused write *inside* `data` — the payload's own
   * `errors` field, with `result: null` — not as a top-level error, so select
   * `errors { message code }` on mutations and check it.
   */
  async graphql<TData = Record<string, unknown>>(
    query: string,
    variables: Record<string, unknown> = {},
    options: GraphQLOptions = {},
  ): Promise<TData> {
    const payload: Record<string, unknown> = { query, variables };
    if (options.operationName !== undefined) payload.operationName = options.operationName;

    let body: GraphQLResponse<TData>;
    try {
      body = (await this.send("POST", "/gql", {
        signal: options.signal,
        accept: "application/json",
        contentType: "application/json",
        body: payload,
      })) as GraphQLResponse<TData>;
    } catch (error) {
      // Absinthe refuses an unparseable document with a 400 whose body is
      // still GraphQL-shaped; surface that as the GraphQL error it is.
      if (error instanceof KilnHttpError && error.status === 400) {
        const errors = graphqlErrors(error.body);
        if (errors.length > 0) throw new KilnGraphQLError(errors, null, 400);
      }
      throw error;
    }

    const errors = graphqlErrors(body);
    if (errors.length > 0) throw new KilnGraphQLError(errors, body?.data ?? null, 200);
    return (body?.data ?? {}) as TData;
  }

  // ── transport ─────────────────────────────────────────────────────────────

  private request(
    path: string,
    params: URLSearchParams,
    signal: AbortSignal | undefined,
    accept = JSON_API,
    method: "GET" | "POST" = "GET",
  ): Promise<unknown> {
    return this.send(method, path, { params, signal, accept });
  }

  // Writes fail fast without a key: an anonymous write can only be refused,
  // and finding that out client-side costs no round trip and no rate-limit
  // budget. The message names the option, never a value.
  private async write(
    method: "POST" | "PATCH" | "DELETE",
    path: string,
    body: unknown,
    signal: AbortSignal | undefined,
  ): Promise<unknown> {
    if (!this.hasApiKey()) {
      throw new KilnConfigError(
        `${method} ${path} writes to Kiln and needs an API key: pass \`apiKey\` to ` +
          "createClient() — a :read_write key on an editor (create/update/submit) " +
          "or admin (publish/unpublish/return/delete) account.",
        "missing_api_key",
      );
    }
    return this.send(method, path, {
      signal,
      accept: JSON_API,
      contentType: body === undefined ? undefined : JSON_API,
      body,
    });
  }

  private hasApiKey(): boolean {
    return this.apiKey !== undefined && this.apiKey !== "";
  }

  private async send(
    method: string,
    path: string,
    request: {
      params?: URLSearchParams;
      signal?: AbortSignal;
      accept: string;
      contentType?: string;
      body?: unknown;
    },
  ): Promise<unknown> {
    const query = request.params?.toString() ?? "";
    const url = this.baseUrl + path + (query === "" ? "" : `?${query}`);

    const headers: Record<string, string> = { accept: request.accept, ...this.headers };
    if (request.contentType !== undefined) headers["content-type"] = request.contentType;
    if (this.hasApiKey()) headers.authorization = `Bearer ${this.apiKey}`;

    const init: RequestInit = {
      method,
      headers,
      signal: request.signal ?? AbortSignal.timeout(this.timeoutMs),
    };
    if (request.body !== undefined) init.body = JSON.stringify(request.body);

    let response: Response;
    try {
      response = await this.fetchImpl(url, init);
    } catch (error) {
      // Cancellation stays the platform's own error, so `signal` handling
      // written against plain fetch keeps working; everything else is a
      // network failure the caller can recognise without string-matching.
      if (isAbort(error)) throw error;
      throw new KilnNetworkError(url, error);
    }

    if (!response.ok) {
      const retryAfter = parseRetryAfter(response.headers.get("retry-after"));
      throw httpError(response.status, url, await errorBody(response), retryAfter);
    }

    // A 204 (or any empty 2xx — a soft-delete may answer either way) has no
    // document to parse.
    const text = await response.text();
    return text === "" ? null : JSON.parse(text);
  }
}

// The singular JSON:API `type` the server validates `data.type` against.
// Every built-in plural is regular (`posts`, `pages`) or `-ies` (`entries`);
// an irregular overlay type passes `type` explicitly.
function resourceType(plural: string, options: WriteOptions): string {
  if (options.type !== undefined) return options.type;
  if (plural.endsWith("ies")) return `${plural.slice(0, -3)}y`;
  return plural.endsWith("s") ? plural.slice(0, -1) : plural;
}

// Every write route answers a single-resource document.
function onlyItem<T extends Item>(doc: unknown): T {
  const item = flattenDocument<T>(doc).items[0];
  if (item === undefined) {
    throw new KilnError("Kiln answered a write with no resource document", {
      code: "empty_response",
    });
  }
  return item;
}

function graphqlErrors(body: unknown): GraphQLErrorObject[] {
  if (body === null || typeof body !== "object" || !("errors" in body)) return [];
  const errors = (body as { errors: unknown }).errors;
  return Array.isArray(errors)
    ? errors.filter(
        (error): error is GraphQLErrorObject => error !== null && typeof error === "object",
      )
    : [];
}

// By name, not `instanceof`: an abort is a `DOMException`, which not every
// runtime this targets makes an `Error` subclass.
function isAbort(error: unknown): boolean {
  if (error === null || typeof error !== "object" || !("name" in error)) return false;
  const name = (error as { name: unknown }).name;
  return name === "AbortError" || name === "TimeoutError";
}

// Published-only unless a caller explicitly opts out. Safe by default: the
// alternative (opting *in* per call site) re-arms the moment someone adds one.
function published(options: { published?: boolean }): boolean {
  return options.published !== false;
}

function asOfParam(asOf: string | Date): string {
  return asOf instanceof Date ? asOf.toISOString() : asOf;
}

async function errorBody(response: Response): Promise<unknown> {
  const text = await response.text().catch(() => "");
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

// Resolves after `ms`, or rejects as soon as `signal` aborts (immediately if
// it already has) — so a wait between retries can never outlive the bound the
// caller put on the whole call.
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortReason(signal));
      return;
    }
    const onAbort = () => {
      clearTimeout(timer);
      reject(abortReason(signal!));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}
