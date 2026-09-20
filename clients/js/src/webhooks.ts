/**
 * Verifying KilnCMS outbound webhooks.
 *
 * Every delivery carries `x-kilncms-webhook-signature: t=<unix>,v1=<hex>`,
 * where `v1` is the HMAC-SHA256 of `"<t>.<raw body>"` keyed by the endpoint's
 * signing secret. The timestamp is inside the MAC, so a receiver that refuses
 * a `t` outside its window refuses a replayed capture. See `docs/webhooks.md`.
 *
 * Uses Web Crypto (`globalThis.crypto.subtle`), available in Node 20+, Deno,
 * Bun, Cloudflare Workers and browsers.
 */

/** The header carrying the timestamped signature. */
export const WEBHOOK_SIGNATURE_HEADER = "x-kilncms-webhook-signature";
/** The header echoing the body's `delivery_id`. */
export const WEBHOOK_DELIVERY_ID_HEADER = "x-kilncms-delivery-id";
/** The window the server documents, in seconds. */
export const WEBHOOK_TOLERANCE_SECONDS = 300;

/** The JSON body of every delivery. */
export interface WebhookDelivery<Data = Record<string, unknown>> {
  /** `"<type>.<verb>"`, e.g. `"page.published"`, or `"form.submitted"`, `"ping"`, … */
  event: string;
  /** The ledger row's id: stable across retries, new for a redelivery. */
  delivery_id?: string;
  data: Data;
}

export type WebhookVerification =
  { ok: true } | { ok: false; reason: "malformed" | "expired" | "mismatch" };

export interface VerifyWebhookOptions {
  /** Seconds `t` may stray from `now`. Defaults to 300. */
  toleranceSeconds?: number;
  /** Unix seconds to check against. Defaults to the system clock. */
  now?: number;
}

/**
 * Verify a delivery. `body` must be the raw request body exactly as received:
 * a re-serialized parse won't match.
 *
 * ```ts
 * const raw = await request.text();
 * const result = await verifyWebhook(secret, raw, request.headers.get(WEBHOOK_SIGNATURE_HEADER));
 * if (!result.ok) return new Response(result.reason, { status: 400 });
 * const delivery = JSON.parse(raw) as WebhookDelivery;
 * ```
 */
export async function verifyWebhook(
  secret: string,
  body: string | Uint8Array,
  header: string | null | undefined,
  opts: VerifyWebhookOptions = {},
): Promise<WebhookVerification> {
  const parsed = header ? parseSignature(header) : null;
  if (!parsed) return { ok: false, reason: "malformed" };

  const tolerance = opts.toleranceSeconds ?? WEBHOOK_TOLERANCE_SECONDS;
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - parsed.timestamp) > tolerance) return { ok: false, reason: "expired" };

  const expected = await hmacHex(secret, concat(`${parsed.timestamp}.`, body));
  return parsed.candidates.some((candidate) => constantTimeEqual(candidate, expected))
    ? { ok: true }
    : { ok: false, reason: "mismatch" };
}

function parseSignature(header: string): { timestamp: number; candidates: string[] } | null {
  const pairs = header.split(",").map((part) => {
    const trimmed = part.trim();
    const eq = trimmed.indexOf("=");
    return eq < 0 ? ["", ""] : [trimmed.slice(0, eq), trimmed.slice(eq + 1)];
  });

  const timestamps = pairs.filter(([k]) => k === "t").map(([, v]) => v!);
  const candidates = pairs
    .filter(([k, v]) => k === "v1" && v !== "")
    .map(([, v]) => v!.toLowerCase());

  const [raw] = timestamps;
  if (timestamps.length !== 1 || !raw || !/^-?\d+$/.test(raw) || candidates.length === 0) {
    return null;
  }
  return { timestamp: Number(raw), candidates };
}

function concat(prefix: string, body: string | Uint8Array): Uint8Array<ArrayBuffer> {
  const encoder = new TextEncoder();
  const head = encoder.encode(prefix);
  const tail = typeof body === "string" ? encoder.encode(body) : body;
  const out = new Uint8Array(head.length + tail.length);
  out.set(head, 0);
  out.set(tail, head.length);
  return out;
}

async function hmacHex(secret: string, data: Uint8Array<ArrayBuffer>): Promise<string> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new Error("verifyWebhook needs Web Crypto (globalThis.crypto.subtle)");

  const key = await subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(await subtle.sign("HMAC", key, data));
  return Array.from(mac, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
