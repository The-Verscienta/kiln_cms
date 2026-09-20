import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  createClient,
  DEFAULT_TRANSFORM_SIZES,
  signedTransformPath,
  signedTransformSrcset,
  snapTransformSize,
  transformPath,
  transformSrcset,
  transformVersion,
  type TransformMedia,
  type TransformOptions,
  type TransformSrcsetOptions,
} from "../src/index.js";

/**
 * The shared image-transform vectors, generated from the server's
 * `KilnCMS.Media.ImageTransform` by `scripts/generate_image_transform_vectors.exs`
 * and asserted verbatim by the server, this SDK and the Elixir client — so a
 * grammar change that isn't mirrored in all three turns exactly one side red.
 * Never edit the fixture to make this pass.
 */

type RawOptions = Record<string, unknown>;

interface UrlVector {
  name: string;
  media: string;
  key: string | null;
  options: RawOptions;
  expected: string;
}

interface SrcsetVector extends Omit<UrlVector, "expected"> {
  widths: number[] | null;
  expected: string | null;
}

interface Vectors {
  media: Record<string, TransformMedia>;
  sizes: number[];
  signing_key: string;
  versions: { media: string; expected: string | null }[];
  urls: UrlVector[];
  srcsets: SrcsetVector[];
}

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(
  readFileSync(join(here, "fixtures", "image_transform_vectors.json"), "utf8"),
) as Vectors;

function media(name: string): TransformMedia {
  const item = vectors.media[name];
  if (item === undefined) throw new Error(`unknown fixture media ${name}`);
  return item;
}

// The fixture's option keys are the Elixir builder's (`aspect_ratio`).
function options(raw: RawOptions): TransformOptions {
  const camel = Object.fromEntries(
    Object.entries(raw).map(([key, value]) => [
      key.replace(/_([a-z])/g, (_, char: string) => char.toUpperCase()),
      value,
    ]),
  );
  return camel as TransformOptions;
}

describe("image transform vectors", () => {
  it("pins the default size ladder to the server's", () => {
    expect(DEFAULT_TRANSFORM_SIZES).toEqual(vectors.sizes);
  });

  it.each(vectors.versions)("version of $media", ({ media: name, expected }) => {
    expect(transformVersion(media(name))).toBe(expected);
  });

  it.each(vectors.urls)("url: $name", async ({ media: name, key, options: raw, expected }) => {
    const path =
      key === null
        ? transformPath(media(name), options(raw))
        : await signedTransformPath(media(name), options(raw), key);
    expect(path).toBe(expected);
  });

  it.each(vectors.srcsets)(
    "srcset: $name",
    async ({ media: name, key, options: raw, widths, expected }) => {
      const opts: TransformSrcsetOptions = {
        ...options(raw),
        ...(widths === null ? {} : { widths }),
      };
      const srcset =
        key === null
          ? transformSrcset(media(name), opts)
          : await signedTransformSrcset(media(name), opts, key);
      expect(srcset).toBe(expected);
    },
  );
});

describe("transform builders", () => {
  const photo = media("photo");

  it("accepts the aspect ratio as a tuple", () => {
    expect(transformPath(photo, { width: 1080, aspectRatio: [16, 9] })).toBe(
      transformPath(photo, { width: 1080, aspectRatio: "16:9" }),
    );
  });

  it("snaps to an operator-configured ladder", () => {
    expect(snapTransformSize(700, [1000, 500])).toBe(1000);
    expect(snapTransformSize(5000, [1000, 500])).toBe(1000);
    expect(transformPath(photo, { width: 700, sizes: [500, 1000] })).toMatch(/\/t\/w_1000,/);
  });

  it("rejects invalid options with a clear error", () => {
    expect(() => transformPath(photo, { width: 800.5 })).toThrow(/width must be a positive/);
    expect(() => transformPath(photo, { width: 0 })).toThrow(/width must be a positive/);
    expect(() => transformPath(photo, { quality: 101 })).toThrow(/quality must be 1-100/);
    expect(() => transformPath(photo, { quality: 0 })).toThrow(/quality must be a positive/);
    expect(() => transformPath(photo, { dpr: 4 as 1 })).toThrow(/dpr must be 1, 2 or 3/);
    expect(() => transformPath(photo, { fit: "fill" as "cover" })).toThrow(
      /fit must be one of/,
    );
    expect(() => transformPath(photo, { crop: "middle" as "top" })).toThrow(/crop must be one/);
    expect(() => transformPath(photo, { format: "gif" as "png" })).toThrow(/format must be/);
    expect(() => transformPath(photo, { aspectRatio: "16x9" })).toThrow(/aspectRatio must/);
    expect(() => transformPath(photo, { aspectRatio: [100, 1] })).toThrow(/aspectRatio must/);
    expect(() => transformPath(photo, { height: 300, aspectRatio: "1:1" })).toThrow(/not both/);
    expect(() => transformSrcset(photo, { widths: [-1] })).toThrow(/widths\[\] must be/);
  });

  it("rejects signing without a key", async () => {
    await expect(signedTransformPath(photo, { width: 800 }, "")).rejects.toThrow(/signing key/);
  });

  it("ignores a height passed to a srcset by a plain-JS caller", () => {
    const withHeight = { widths: [640], height: 300 } as TransformSrcsetOptions;
    expect(transformSrcset(photo, withHeight)).toBe(transformSrcset(photo, { widths: [640] }));
  });
});

describe("KilnClient image helpers", () => {
  const photo = media("photo");
  const origin = "https://cms.example.com";

  it("builds absolute unsigned URLs from the client's baseUrl", () => {
    const kiln = createClient({ baseUrl: `${origin}/` });

    expect(kiln.imageUrl(photo, { width: 800 })).toBe(
      `${origin}${transformPath(photo, { width: 800 })}`,
    );
    expect(kiln.imageSrcset(photo, { widths: [300, 640] })).toBe(
      `${origin}/media/${photo.id}/t/w_384,v_4b87b277 384w, ` +
        `${origin}/media/${photo.id}/t/w_640,v_4b87b277 640w`,
    );
    expect(kiln.imageSrcset({ id: photo.id })).toBeNull();
  });

  it("signs with the configured imageTransformKey", async () => {
    const kiln = createClient({ baseUrl: origin, imageTransformKey: vectors.signing_key });
    const opts = { width: 801, height: 451 };

    expect(await kiln.signedImageUrl(photo, opts)).toBe(
      origin + (await signedTransformPath(photo, opts, vectors.signing_key)),
    );

    const srcset = await kiln.signedImageSrcset(photo, { widths: [300, 600] });
    expect(srcset).toBe(
      (await signedTransformSrcset(photo, { widths: [300, 600] }, vectors.signing_key))!
        .split(", ")
        .map((candidate) => origin + candidate)
        .join(", "),
    );
  });

  it("refuses to sign without a key", async () => {
    const kiln = createClient({ baseUrl: origin });

    await expect(kiln.signedImageUrl(photo, { width: 800 })).rejects.toThrow(
      /imageTransformKey/,
    );
    await expect(kiln.signedImageSrcset(photo)).rejects.toThrow(/imageTransformKey/);
  });
});
