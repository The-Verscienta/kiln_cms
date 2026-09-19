/**
 * The client's error hierarchy. Every error it throws is a `KilnError`; an
 * HTTP answer outside 2xx is a `KilnHttpError` (unchanged since 0.1 — `status`,
 * `url`, `body`), refined into a subclass by status so callers can branch with
 * `instanceof` instead of re-deriving the mapping at every call site:
 *
 *     KilnError                    base: status?, code?, errors[], retryAfter?
 *     ├─ KilnHttpError             any non-2xx response
 *     │  ├─ KilnAuthError          401 (no/invalid key) · 403 (key lacks the right)
 *     │  ├─ KilnNotFoundError      404
 *     │  ├─ KilnValidationError    400 / 422 — field pointers in `pointers`
 *     │  ├─ KilnConflictError      409 — wrong-state transition or a lost race
 *     │  ├─ KilnRateLimitError     429 — `retryAfter` seconds
 *     │  └─ KilnServerError        5xx
 *     ├─ KilnNetworkError          fetch itself failed (DNS, refused, TLS…)
 *     ├─ KilnGraphQLError          `/gql` answered with `errors`
 *     └─ KilnConfigError           refused client-side (a write with no API key)
 *
 * Aborts are the one thing deliberately *not* wrapped: a caller's own
 * `AbortSignal` (or the client's timeout) rejects with the platform's
 * `AbortError`/`TimeoutError`, exactly as `fetch` does, so existing
 * `signal`-based cancellation code keeps working.
 *
 * Kiln answers every headless refusal in one envelope (`KilnCMSWeb.ApiError`,
 * and AshJsonApi's own errors on `/api/json`):
 * `{"errors": [{"status": "409", "code": "…", "detail": "…", "source": {"pointer": "…"}, "meta": {…}}]}`.
 * `errors` is that array; `code` is its first entry's code.
 */

/** One JSON:API error object, as Kiln serializes it. */
export interface KilnErrorObject {
  /** HTTP status as a numeric string (`"409"`), per JSON:API. */
  status?: string;
  /** Machine-readable code — branch on this, not on `detail`. */
  code?: string;
  title?: string;
  detail?: string;
  /** `pointer` names the offending field, e.g. `/data/attributes/slug`. */
  source?: { pointer?: string; parameter?: string };
  /** e.g. `{ current_state: "published" }` on an `invalid_state_transition`. */
  meta?: Record<string, unknown>;
  [key: string]: unknown;
}

/** One GraphQL error, as `/gql` returns it under the top-level `errors`. */
export interface GraphQLErrorObject {
  message: string;
  path?: (string | number)[];
  locations?: { line: number; column: number }[];
  /** Ash's GraphQL errors carry a machine-readable `code` here or in `extensions`. */
  code?: string;
  extensions?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface KilnErrorInit {
  status?: number;
  code?: string;
  errors?: KilnErrorObject[];
  retryAfter?: number;
  cause?: unknown;
}

/** Base of every error this client throws. */
export class KilnError extends Error {
  /** HTTP status, when a response was received. */
  readonly status: number | undefined;
  /** First error object's `code` (or the client's own code for local errors). */
  readonly code: string | undefined;
  /** The JSON:API `errors` array (empty when the body carried none). */
  readonly errors: KilnErrorObject[];
  /** Seconds to wait before retrying, from `Retry-After` (429, 503). */
  readonly retryAfter: number | undefined;

  constructor(message: string, init: KilnErrorInit = {}) {
    super(message, init.cause === undefined ? undefined : { cause: init.cause });
    this.name = "KilnError";
    this.status = init.status;
    this.code = init.code;
    this.errors = init.errors ?? [];
    this.retryAfter = init.retryAfter;
  }
}

/** A non-2xx HTTP response from a Kiln surface. */
export class KilnHttpError extends KilnError {
  declare readonly status: number;
  readonly url: string;
  /** Parsed JSON error body when the server sent one, else the raw text. */
  readonly body: unknown;

  constructor(status: number, url: string, body: unknown, retryAfter?: number) {
    const errors = errorObjects(body);
    const detail = errors[0]?.detail;
    super(`Kiln request failed: ${status} ${url}${detail ? ` — ${detail}` : ""}`, {
      status,
      code: errors[0]?.code,
      errors,
      retryAfter,
    });
    this.name = "KilnHttpError";
    this.url = url;
    this.body = body;
  }
}

/**
 * 401 — no credential, or an invalid/expired/revoked `kiln_…` key; 403 — the
 * key's owner lacks the right (a `:read` key writing, an editor publishing).
 */
export class KilnAuthError extends KilnHttpError {
  override name = "KilnAuthError";
}

/** 404 — no such record (or one the credential cannot see). */
export class KilnNotFoundError extends KilnHttpError {
  override name = "KilnNotFoundError";
}

/**
 * 400 / 422 — the request was refused as invalid. AshJsonApi answers most
 * attribute errors with **400**, not 422, so both land here. `pointers` lists
 * the offending fields (`/data/attributes/slug`).
 */
export class KilnValidationError extends KilnHttpError {
  override name = "KilnValidationError";

  /** Every `source.pointer` the server named, in order. */
  get pointers(): string[] {
    return this.errors
      .map((error) => error.source?.pointer)
      .filter((pointer): pointer is string => typeof pointer === "string");
  }

  /** Details grouped by attribute name (`/data/attributes/slug` → `slug`). */
  fieldErrors(): Record<string, string[]> {
    const byField: Record<string, string[]> = {};
    for (const error of this.errors) {
      const pointer = error.source?.pointer;
      if (typeof pointer !== "string") continue;
      const field = pointer.replace(/^\/data\/attributes\//, "");
      (byField[field] ??= []).push(error.detail ?? error.title ?? error.code ?? "invalid");
    }
    return byField;
  }
}

/**
 * 409 — a workflow transition from the wrong state (`invalid_state_transition`,
 * with the record's actual state in `currentState`), or a write that lost a
 * race to a concurrent one. Reload and decide; retrying blindly repeats it.
 */
export class KilnConflictError extends KilnHttpError {
  override name = "KilnConflictError";

  /** `meta.current_state` of the first error, when the server reported one. */
  get currentState(): string | undefined {
    const state = this.errors[0]?.meta?.current_state;
    return typeof state === "string" ? state : undefined;
  }
}

/** 429 — the per-IP rate limit. Wait `retryAfter` seconds. */
export class KilnRateLimitError extends KilnHttpError {
  override name = "KilnRateLimitError";
}

/** 5xx — a server fault or a cold cache (503, which may carry `retryAfter`). */
export class KilnServerError extends KilnHttpError {
  override name = "KilnServerError";
}

/** The request never produced a response (DNS, connection refused, TLS…). */
export class KilnNetworkError extends KilnError {
  readonly url: string;

  constructor(url: string, cause: unknown) {
    const reason = cause instanceof Error ? cause.message : String(cause);
    super(`Kiln request failed: ${url} — ${reason}`, { code: "network_error", cause });
    this.name = "KilnNetworkError";
    this.url = url;
  }
}

/**
 * `/gql` answered with a top-level `errors` array (a parse/validation error,
 * or a resolver that failed). `data` is whatever partial result came with it.
 *
 * Ash mutations report their own failures *inside* `data` (the payload's
 * `errors` field) with no top-level `errors` — select that field and check it.
 */
export class KilnGraphQLError extends KilnError {
  readonly graphqlErrors: GraphQLErrorObject[];
  readonly data: unknown;

  constructor(graphqlErrors: GraphQLErrorObject[], data: unknown, status?: number) {
    const first = graphqlErrors[0];
    const code = first?.code ?? stringOrUndefined(first?.extensions?.code);
    super(`Kiln GraphQL request failed: ${first?.message ?? "unknown error"}`, {
      status,
      code,
    });
    this.name = "KilnGraphQLError";
    this.graphqlErrors = graphqlErrors;
    this.data = data;
  }
}

/** Refused before any request was sent — the client is not configured for it. */
export class KilnConfigError extends KilnError {
  constructor(message: string, code: string) {
    super(message, { code });
    this.name = "KilnConfigError";
  }
}

/** Build the `KilnHttpError` subclass matching `status`. */
export function httpError(
  status: number,
  url: string,
  body: unknown,
  retryAfter?: number,
): KilnHttpError {
  if (status === 401 || status === 403) return new KilnAuthError(status, url, body, retryAfter);
  if (status === 404) return new KilnNotFoundError(status, url, body, retryAfter);
  if (status === 400 || status === 422)
    return new KilnValidationError(status, url, body, retryAfter);
  if (status === 409) return new KilnConflictError(status, url, body, retryAfter);
  if (status === 429) return new KilnRateLimitError(status, url, body, retryAfter);
  if (status >= 500) return new KilnServerError(status, url, body, retryAfter);
  return new KilnHttpError(status, url, body, retryAfter);
}

/**
 * `Retry-After` as seconds: delta-seconds, or an HTTP date (seconds from
 * `now`, floored at 0). `undefined` when absent or unparseable.
 */
export function parseRetryAfter(
  value: string | null,
  now: number = Date.now(),
): number | undefined {
  if (value === null || value.trim() === "") return undefined;
  if (/^\d+$/.test(value.trim())) return Number(value.trim());
  const date = Date.parse(value);
  return Number.isNaN(date) ? undefined : Math.max(0, Math.ceil((date - now) / 1000));
}

/** Narrowing helper: `isKilnError(err) && err.code === "invalid_state_transition"`. */
export function isKilnError(error: unknown): error is KilnError {
  return error instanceof KilnError;
}

/** Narrowing helper: `isKilnHttpError(err) && err.status === 404`. */
export function isKilnHttpError(error: unknown): error is KilnHttpError {
  return error instanceof KilnHttpError;
}

function errorObjects(body: unknown): KilnErrorObject[] {
  if (body === null || typeof body !== "object" || !("errors" in body)) return [];
  const errors = (body as { errors: unknown }).errors;
  if (!Array.isArray(errors)) return [];
  return errors.filter(
    (error): error is KilnErrorObject => error !== null && typeof error === "object",
  );
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
