/**
 * Image-transform URL builders for Kiln's on-the-fly transform endpoint,
 * `GET /media/:id/t/:ops` — e.g. `/media/<id>/t/w_828,ar_16:9,fm_auto,v_3f2a9c01`.
 *
 * A port of the server-side builders (`KilnCMS.Media.ImageTransform.url/2` and
 * `srcset/3`). All three implementations — server, this SDK and the Elixir
 * client — are pinned to the same URLs by the shared vectors in
 * `test/fixtures/image_transform_vectors.json`, so a change to the grammar
 * that isn't mirrored everywhere turns a suite red.
 *
 * ## Unsigned vs signed
 *
 * Every distinct parameter set costs the server a decode, a resize and an
 * encode, so unsigned URLs are held to an allowlist: widths and heights from
 * a size ladder (Next.js's default `deviceSizes ++ imageSizes`, operator
 * configurable), and off-ladder values are a 400. The unsigned builders
 * therefore **snap `width`/`height` up** to the next rung — pass `sizes` if
 * the operator changed the ladder. Aspect ratios and qualities have
 * allowlists too (by default `1:1 4:3 3:4 3:2 2:3 4:5 5:4 16:9 9:16 21:9` and
 * `50 75 90`); those are not snapped, so stay on them.
 *
 * Signed URLs may use any in-range value and are not snapped. The signature is
 * an HMAC-SHA256 under the server's `KILN_IMAGE_TRANSFORM_KEY` — a secret:
 * sign on a server (SSR, a build step), never in a browser bundle.
 *
 * ## Version pin
 *
 * `v` is a hash of the item's `url` and focal point, so a replaced image or a
 * moved focal point yields a new URL. The server serves a URL whose `v`
 * matches as `immutable` for a year; without one, it is cached for minutes.
 */

// ── types ───────────────────────────────────────────────────────────────────

/** `cover` (default) fills the box and crops; `contain` fits inside it. */
export type TransformFit = "cover" | "contain";

/** Where a `cover` crop is anchored; `focal` (default) uses the item's focal point. */
export type TransformCrop = "focal" | "center" | "top" | "bottom" | "left" | "right";

/**
 * Output format. `auto` negotiates from the request's `Accept` header (AVIF
 * when the operator opted in, then WebP, then the source format); omitted,
 * the output keeps the source's format.
 */
export type TransformFormat = "auto" | "jpg" | "png" | "webp" | "avif";

/**
 * The media fields the builders read — the shape of a flattened JSON:API
 * `media_item` (`kiln.list("media-items")`). `url` and the focal point feed
 * the version pin; `width`/`height` bound a `srcset`.
 */
export interface TransformMedia {
  id: string;
  url?: string | null;
  focal_x?: number | null;
  focal_y?: number | null;
  width?: number | null;
  height?: number | null;
}

export interface TransformOptions {
  /** Width in CSS px (`w`). Snapped up to the ladder when unsigned. */
  width?: number;
  /** Height in CSS px (`h`). Snapped up to the ladder when unsigned; not with `aspectRatio`. */
  height?: number;
  /** Aspect ratio width:height (`ar`), as `"16:9"` or `[16, 9]`; each side 1–99. */
  aspectRatio?: string | readonly [number, number];
  /** Device-pixel ratio (`dpr`): multiplies the output size. */
  dpr?: 1 | 2 | 3;
  fit?: TransformFit;
  crop?: TransformCrop;
  /** Output format (`fm`). */
  format?: TransformFormat;
  /** Quality 1–100 (`q`), lossy formats only. */
  quality?: number;
  /**
   * The server's size ladder, for snapping unsigned sizes (default
   * `DEFAULT_TRANSFORM_SIZES`). Only needed when the operator configured a
   * different one.
   */
  sizes?: readonly number[];
}

export interface TransformSrcsetOptions extends Omit<TransformOptions, "height"> {
  /**
   * Candidate widths (default: the ladder's rungs from 256 up). Snapped and
   * deduplicated when unsigned. For a cropped set pass `aspectRatio` — a fixed
   * height would give every candidate a different shape.
   */
  widths?: readonly number[];
}

/**
 * The server's default size ladder — Next.js's default
 * `deviceSizes ++ imageSizes`.
 */
export const DEFAULT_TRANSFORM_SIZES: readonly number[] = Object.freeze([
  16, 32, 48, 64, 96, 128, 256, 384, 640, 750, 828, 1080, 1200, 1920, 2048, 3840,
]);

// ── public builders ─────────────────────────────────────────────────────────

/**
 * The version pin (`v`) for `media`: FNV-1a 32-bit over
 * `"<url>|<round(focal_x * 1000)>|<round(focal_y * 1000)>"`, as 8 lowercase
 * hex digits, with a missing focal point read as the centre. `null` for an
 * item with no `url` — a pin of nothing could never match the server's.
 */
export function transformVersion(media: TransformMedia): string | null {
  if (media.url === null || media.url === undefined) return null;
  const input = `${media.url}|${milli(media.focal_x)}|${milli(media.focal_y)}`;
  return fnv1a32(new TextEncoder().encode(input)).toString(16).padStart(8, "0");
}

/** Snaps `value` up to the next rung of `sizes` (the top rung, past the top). */
export function snapTransformSize(
  value: number,
  sizes: readonly number[] = DEFAULT_TRANSFORM_SIZES,
): number {
  const ladder = checkLadder(sizes);
  return ladder.find((size) => size >= value) ?? ladder[ladder.length - 1]!;
}

/**
 * An unsigned transform path, `/media/<id>/t/<ops>`, with `width`/`height`
 * snapped up to the size ladder so the server's allowlist accepts it:
 *
 *     transformPath(media, { width: 800, aspectRatio: "16:9", format: "auto" });
 *     // → "/media/<id>/t/w_828,ar_16:9,fm_auto,v_4b87b277"
 *
 * Throws on an invalid option (a non-integer width, a quality out of range, an
 * unknown enum value, `height` together with `aspectRatio`).
 */
export function transformPath(media: TransformMedia, options: TransformOptions = {}): string {
  return pathFor(media, canonicalOps(media, options, true));
}

/**
 * A signed transform path: any in-range size, no snapping, with an `s`
 * signature under `key` — the server's `KILN_IMAGE_TRANSFORM_KEY`.
 *
 * **Server-side only.** Anyone holding the key can make the server render
 * arbitrary sizes; never ship it to a browser.
 *
 * Async because it signs with WebCrypto (`globalThis.crypto.subtle`).
 */
export async function signedTransformPath(
  media: TransformMedia,
  options: TransformOptions,
  key: string,
): Promise<string> {
  const ops = canonicalOps(media, options, false);
  const signature = await sign(await importKey(key), media.id, ops);
  return pathFor(media, appendSignature(ops, signature));
}

/**
 * An unsigned `srcset` of transform paths — widths snapped up to the ladder —
 * for `media`, or `null` when its `width`/`height` are unknown:
 *
 *     <img srcset={transformSrcset(media, { aspectRatio: "16:9", format: "auto" })} …>
 *
 * Each candidate is described by the width it can really render at (the
 * server never upscales): `min(w, widest)`, where `widest` is the item's width
 * or, with an aspect ratio, the width of the largest window of that shape.
 * Candidates past `widest` would all render at it, so only the first is kept.
 */
export function transformSrcset(
  media: TransformMedia,
  options: TransformSrcsetOptions = {},
): string | null {
  return buildTransformSrcset(media, options, "");
}

/**
 * `transformSrcset`, signed under `key`: widths used exactly as given. Same
 * server-side-only caveat as `signedTransformPath`.
 */
export function signedTransformSrcset(
  media: TransformMedia,
  options: TransformSrcsetOptions,
  key: string,
): Promise<string | null> {
  return buildSignedTransformSrcset(media, options, key, "");
}

// ── internals shared with KilnClient (not re-exported from the index) ───────

/** @internal `transformSrcset` with every candidate prefixed by `origin`. */
export function buildTransformSrcset(
  media: TransformMedia,
  options: TransformSrcsetOptions,
  origin: string,
): string | null {
  const candidates = srcsetCandidates(media, options, true);
  if (candidates === null) return null;

  return candidates
    .map(({ width, described }) => {
      const ops = canonicalOps(media, candidateOptions(options, width), false);
      return `${origin}${pathFor(media, ops)} ${described}w`;
    })
    .join(", ");
}

/** @internal `signedTransformSrcset` with every candidate prefixed by `origin`. */
export async function buildSignedTransformSrcset(
  media: TransformMedia,
  options: TransformSrcsetOptions,
  key: string,
  origin: string,
): Promise<string | null> {
  const candidates = srcsetCandidates(media, options, false);
  if (candidates === null) return null;

  const cryptoKey = await importKey(key);
  const entries = await Promise.all(
    candidates.map(async ({ width, described }) => {
      const ops = canonicalOps(media, candidateOptions(options, width), false);
      const signature = await sign(cryptoKey, media.id, ops);
      return `${origin}${pathFor(media, appendSignature(ops, signature))} ${described}w`;
    }),
  );
  return entries.join(", ");
}

// ── canonical form ──────────────────────────────────────────────────────────

const FITS: readonly TransformFit[] = ["cover", "contain"];
const CROPS: readonly TransformCrop[] = ["focal", "center", "top", "bottom", "left", "right"];
const FORMATS: readonly TransformFormat[] = ["auto", "jpg", "png", "webp", "avif"];

// The canonical `<ops>` (without `s`): `w, h, ar, dpr, fit, crop, fm, q, v`,
// each only when given — the exact string the server's signature covers.
function canonicalOps(media: TransformMedia, options: TransformOptions, snap: boolean): string {
  if (typeof media.id !== "string" || media.id === "") {
    throw new Error("Kiln image transform: media.id must be a non-empty string.");
  }

  const sizes = options.sizes ?? DEFAULT_TRANSFORM_SIZES;
  const size = (key: string, value: number | undefined): number | undefined => {
    if (value === undefined) return undefined;
    positiveInteger(key, value);
    return snap ? snapTransformSize(value, sizes) : value;
  };

  const w = size("width", options.width);
  const h = size("height", options.height);
  const ar = options.aspectRatio === undefined ? undefined : ratio(options.aspectRatio);

  if (h !== undefined && ar !== undefined) {
    throw new Error("Kiln image transform: pass height or aspectRatio, not both.");
  }
  if (options.dpr !== undefined && !([1, 2, 3] as unknown[]).includes(options.dpr)) {
    throw new Error(
      `Kiln image transform: dpr must be 1, 2 or 3 (got ${String(options.dpr)}).`,
    );
  }
  oneOf("fit", options.fit, FITS);
  oneOf("crop", options.crop, CROPS);
  oneOf("format", options.format, FORMATS);
  if (options.quality !== undefined) {
    positiveInteger("quality", options.quality);
    if (options.quality > 100) {
      throw new Error(`Kiln image transform: quality must be 1-100 (got ${options.quality}).`);
    }
  }

  const params: [string, string | number | undefined][] = [
    ["w", w],
    ["h", h],
    ["ar", ar],
    ["dpr", options.dpr],
    ["fit", options.fit],
    ["crop", options.crop],
    ["fm", options.format],
    ["q", options.quality],
    ["v", transformVersion(media) ?? undefined],
  ];

  return params
    .filter((param): param is [string, string | number] => param[1] !== undefined)
    .map(([key, value]) => `${key}_${value}`)
    .join(",");
}

function pathFor(media: TransformMedia, ops: string): string {
  return `/media/${media.id}/t/${ops}`;
}

function appendSignature(ops: string, signature: string): string {
  return ops === "" ? `s_${signature}` : `${ops},s_${signature}`;
}

function ratio(value: string | readonly [number, number]): string {
  const parts =
    typeof value === "string"
      ? value.split(":").map((part) => parseRatioSide(part))
      : [...value];
  const [a, b] = parts;
  if (parts.length !== 2 || !ratioSide(a) || !ratioSide(b)) {
    throw new Error(
      `Kiln image transform: aspectRatio must be "a:b" or [a, b] with integers 1-99 (got ${JSON.stringify(value)}).`,
    );
  }
  return `${a}:${b}`;
}

// Digits only, no leading zero — the one spelling the server parses.
function parseRatioSide(part: string): number {
  return /^[1-9][0-9]?$/.test(part) ? Number(part) : NaN;
}

function ratioSide(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= 1 && (value as number) <= 99;
}

function ratioParts(value: string | readonly [number, number]): [number, number] {
  const [a, b] = ratio(value).split(":").map(Number);
  return [a!, b!];
}

function positiveInteger(key: string, value: unknown): void {
  if (!Number.isInteger(value) || (value as number) < 1) {
    throw new Error(
      `Kiln image transform: ${key} must be a positive integer (got ${String(value)}).`,
    );
  }
}

function oneOf(key: string, value: unknown, allowed: readonly string[]): void {
  if (value !== undefined && !allowed.includes(value as string)) {
    throw new Error(
      `Kiln image transform: ${key} must be one of ${allowed.join(", ")} (got ${String(value)}).`,
    );
  }
}

function checkLadder(sizes: readonly number[]): number[] {
  if (sizes.length === 0) throw new Error("Kiln image transform: sizes must not be empty.");
  sizes.forEach((size) => positiveInteger("sizes[]", size));
  return [...sizes].sort((a, b) => a - b);
}

// ── srcset ──────────────────────────────────────────────────────────────────

// A candidate's options: the caller's, at this width — never a `height` (a
// plain-JS caller may pass one anyway), and never snapped again.
function candidateOptions(options: TransformSrcsetOptions, width: number): TransformOptions {
  return { ...options, width, height: undefined };
}

interface SrcsetCandidate {
  width: number;
  described: number;
}

function srcsetCandidates(
  media: TransformMedia,
  options: TransformSrcsetOptions,
  snap: boolean,
): SrcsetCandidate[] | null {
  const { width: sw, height: sh } = media;
  if (!Number.isInteger(sw) || sw! <= 0 || !Number.isInteger(sh) || sh! <= 0) return null;

  let widest = sw!;
  if (options.aspectRatio !== undefined) {
    const [a, b] = ratioParts(options.aspectRatio);
    widest = Math.min(sw!, Math.max(1, roundHalfAwayFromZero((sh! * a) / b)));
  }

  const ladder = checkLadder(options.sizes ?? DEFAULT_TRANSFORM_SIZES);
  const widths = options.widths ?? ladder.filter((size) => size >= 256);
  const sorted = [
    ...new Set(
      widths.map((width) => {
        positiveInteger("widths[]", width);
        return snap ? snapTransformSize(width, ladder) : width;
      }),
    ),
  ].sort((a, b) => a - b);

  const seen = new Set<number>();
  const candidates: SrcsetCandidate[] = [];
  for (const width of sorted) {
    const described = Math.min(width, widest);
    if (seen.has(described)) continue;
    seen.add(described);
    candidates.push({ width, described });
  }
  return candidates;
}

// ── version hash ────────────────────────────────────────────────────────────

// `round(value * 1000)`, a missing value read as the centre. Elixir's `round/1`
// rounds half away from zero; `Math.round` rounds half up (-62.5 → -62).
function milli(value: number | null | undefined): number {
  return typeof value === "number" && Number.isFinite(value)
    ? roundHalfAwayFromZero(value * 1000)
    : 500;
}

function roundHalfAwayFromZero(value: number): number {
  // `+ 0` turns a `-0` into `0`, so it can never print as "-0".
  return Math.sign(value) * Math.round(Math.abs(value)) + 0;
}

function fnv1a32(bytes: Uint8Array): number {
  let hash = 0x811c9dc5;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

// ── signing ─────────────────────────────────────────────────────────────────

function subtleCrypto(): SubtleCrypto {
  const subtle = globalThis.crypto?.subtle;
  if (subtle === undefined) {
    throw new Error(
      "Kiln image transform: signing needs WebCrypto (globalThis.crypto.subtle) — " +
        "Node 19+, or Node 18 with --experimental-global-webcrypto.",
    );
  }
  return subtle;
}

async function importKey(key: string): Promise<CryptoKey> {
  if (typeof key !== "string" || key === "") {
    throw new Error("Kiln image transform: a signing key is required for signed URLs.");
  }
  return subtleCrypto().importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

// HMAC-SHA256 over `"<id>/<canonical ops>"`, truncated to 16 bytes, url-safe
// base64 without padding: 22 characters.
async function sign(key: CryptoKey, id: string, ops: string): Promise<string> {
  const mac = await subtleCrypto().sign("HMAC", key, new TextEncoder().encode(`${id}/${ops}`));
  const bytes = new Uint8Array(mac, 0, 16);
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}
