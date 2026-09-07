/**
 * Typed client for the Kiln CMS delivery APIs — the JSON:API read surface at
 * `/api/json/*`, per-type and hybrid search, fired artifacts at
 * `/api/content/:type/:slug` (including `?as_of=` point-in-time reads), and
 * preview tokens (see Kiln's `docs/json-api.md` and
 * `docs/headless-consumer-guide.md`).
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
 */

import { KilnHttpError } from "./errors.js";
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
  HybridSearchOptions,
  HybridSearchResult,
  Item,
  ListOptions,
  ListResult,
  RequestOptions,
  SearchOptions,
} from "./types.js";

export interface KilnClientOptions {
  /** Base URL of the Kiln instance, e.g. `https://cms.example.com`. */
  baseUrl: string;
  /**
   * Optional bearer API key. Mint delivery keys on a `:viewer` account — an
   * editor/admin key widens what the credential-sensitive routes return (see
   * the module doc and Kiln's `docs/api.md` → "API keys").
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
   * Fetch records by id list (one request, `filter[id][in]=`). Returns the
   * items in `ids` order; ids that resolve to nothing are dropped.
   */
  async byIds<T extends Item = Item>(
    plural: string,
    ids: string[],
    options: ListOptions = {},
  ): Promise<T[]> {
    if (ids.length === 0) return [];
    const { items } = await this.list<T>(plural, {
      ...options,
      filter: { ...options.filter, id: { in: ids } },
      limit: ids.length,
      count: false,
    });
    const byId = new Map(items.map((item) => [item.id, item]));
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
      await sleep(options.retryDelayMs ?? 2_000);
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
    return (await this.request(
      path,
      new URLSearchParams(),
      options.signal,
      "application/json",
    )) as T;
  }

  // ── transport ─────────────────────────────────────────────────────────────

  private async request(
    path: string,
    params: URLSearchParams,
    signal: AbortSignal | undefined,
    accept = "application/vnd.api+json",
  ): Promise<unknown> {
    const query = params.toString();
    const url = this.baseUrl + path + (query === "" ? "" : `?${query}`);

    const headers: Record<string, string> = { accept, ...this.headers };
    if (this.apiKey !== undefined && this.apiKey !== "") {
      headers.authorization = `Bearer ${this.apiKey}`;
    }

    const response = await this.fetchImpl(url, {
      headers,
      signal: signal ?? AbortSignal.timeout(this.timeoutMs),
    });

    if (!response.ok) {
      throw new KilnHttpError(response.status, url, await errorBody(response));
    }
    return response.json();
  }
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
