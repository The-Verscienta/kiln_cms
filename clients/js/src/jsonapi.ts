/**
 * JSON:API document flattening and query-param encoding.
 *
 * Mirrors the official Elixir client (`clients/elixir/kiln_client`): each
 * resource becomes its `attributes` map plus `id`/`type`, with relationships
 * reduced to `{type, id}` ref lists; included resources become a lookup keyed
 * by `refKey(type, id)` so callers can join links without re-walking the
 * document.
 */

import type {
  Filter,
  FilterSpec,
  IncludedMap,
  Item,
  ListOptions,
  ListResult,
  ResourceRef,
} from "./types.js";

// ── flattening ──────────────────────────────────────────────────────────────

/** Key for the `included` lookup. Type names never contain `:`; ids are UUIDs. */
export function refKey(type: string, id: string): string {
  return `${type}:${id}`;
}

interface RawResource {
  id?: string;
  type?: string;
  attributes?: Record<string, unknown>;
  relationships?: Record<string, unknown>;
}

interface RawDocument {
  data?: RawResource | RawResource[];
  included?: RawResource[];
  meta?: { page?: { total?: number } };
}

/** Flatten a raw JSON:API document into `{items, included, total}`. */
export function flattenDocument<T extends Item = Item>(doc: unknown): ListResult<T> {
  const raw = (doc ?? {}) as RawDocument;
  if (raw.data === undefined) return { items: [], included: new Map(), total: null };

  const included: IncludedMap = new Map();
  for (const resource of raw.included ?? []) {
    const item = flattenResource(resource);
    included.set(refKey(item.type, item.id), item);
  }

  const data = Array.isArray(raw.data) ? raw.data : [raw.data];
  const items = data.map((resource) => flattenResource(resource) as T);

  return { items, included, total: raw.meta?.page?.total ?? null };
}

function flattenResource(resource: RawResource): Item {
  const relationships: Record<string, ResourceRef[]> = {};
  for (const [name, value] of Object.entries(resource.relationships ?? {})) {
    relationships[name] = relationshipRefs(value);
  }

  return {
    ...(resource.attributes ?? {}),
    id: resource.id ?? "",
    type: resource.type ?? "",
    relationships,
  };
}

// A relationship without a `data` key (links-only) flattens to no refs.
function relationshipRefs(value: unknown): ResourceRef[] {
  if (value === null || typeof value !== "object" || !("data" in value)) return [];
  const data = (value as { data: unknown }).data;
  const refs = Array.isArray(data) ? data : data === null || data === undefined ? [] : [data];
  return refs
    .filter((ref): ref is { type: string; id: string } => {
      if (ref === null || typeof ref !== "object") return false;
      const candidate = ref as { type?: unknown; id?: unknown };
      return typeof candidate.type === "string" && typeof candidate.id === "string";
    })
    .map((ref) => ({ type: ref.type, id: ref.id }));
}

/** Relationship refs of `item` under `name`, always as a list. */
export function rel(item: Item, name: string): ResourceRef[] {
  return item.relationships[name] ?? [];
}

/** Resolve a relationship of `item` through an included lookup, dropping misses. */
export function resolve(item: Item, name: string, included: IncludedMap): Item[] {
  return rel(item, name)
    .map((ref) => included.get(refKey(ref.type, ref.id)))
    .filter((linked): linked is Item => linked !== undefined);
}

// ── query params ────────────────────────────────────────────────────────────

/**
 * Encode one filter entry under `prefix` (`filter` / `custom_filter`).
 * Objects nest (`filter[price][lte]=10`, `filter[tags][slug]=x`), arrays fan
 * out (`filter[id][in][]=a&filter[id][in][]=b`), scalars are equality.
 */
export function appendFilter(params: URLSearchParams, prefix: string, filter: Filter): void {
  for (const [field, spec] of Object.entries(filter)) {
    appendFilterSpec(params, `${prefix}[${field}]`, spec);
  }
}

function appendFilterSpec(params: URLSearchParams, key: string, spec: FilterSpec): void {
  if (Array.isArray(spec)) {
    for (const value of spec) params.append(`${key}[]`, String(value));
  } else if (spec !== null && typeof spec === "object") {
    for (const [field, nested] of Object.entries(spec)) {
      appendFilterSpec(params, `${key}[${field}]`, nested);
    }
  } else {
    params.append(key, String(spec));
  }
}

/**
 * A bare (non-`filter[...]`) array-typed read-action argument — e.g. the
 * `tag_ids` facet the search actions declare, which JSON:API only resolves as
 * its own top-level `tag_ids[]=` param: `filter[...]` reaches resource fields,
 * never a custom action's own arguments.
 */
export function appendArray(
  params: URLSearchParams,
  key: string,
  values: string[] | undefined,
): void {
  for (const value of values ?? []) params.append(`${key}[]`, value);
}

export function appendSparseFields(
  params: URLSearchParams,
  fields: Record<string, string[]> | undefined,
): void {
  for (const [type, names] of Object.entries(fields ?? {})) {
    params.append(`fields[${type}]`, names.join(","));
  }
}

export function appendIfPresent(
  params: URLSearchParams,
  key: string,
  value: string | number | undefined,
): void {
  if (value !== undefined) params.append(key, String(value));
}

/** The full query for a JSON:API index read. */
export function listParams(options: ListOptions): URLSearchParams {
  const params = new URLSearchParams();
  if (options.filter) appendFilter(params, "filter", options.filter);
  if (options.customFilter) appendFilter(params, "custom_filter", options.customFilter);
  appendIfPresent(params, "sort", options.sort?.join(","));
  appendIfPresent(params, "custom_sort", options.customSort?.join(","));
  appendIfPresent(params, "include", options.include?.join(","));
  appendSparseFields(params, options.fields);
  appendIfPresent(params, "page[limit]", options.limit);
  appendIfPresent(params, "page[offset]", options.offset);
  if (options.count !== false) params.append("page[count]", "true");
  return params;
}
