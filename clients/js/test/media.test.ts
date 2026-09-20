import { describe, expect, it } from "vitest";

import { createClient, isKilnHttpError } from "../src/index.js";
import { stubFetch } from "./helpers.js";

function client(stub: { fetchImpl: typeof globalThis.fetch }) {
  return createClient({
    baseUrl: "https://cms.example.com",
    fetch: stub.fetchImpl,
    apiKey: "kiln_rw",
  });
}

// What the upload routes answer: a JSON:API resource object, plus
// `meta.processing` for an A/V strip still pending.
function created(attributes: Record<string, unknown> = {}, processing = false) {
  return {
    status: 201,
    body: {
      data: {
        type: "media_item",
        id: "m1",
        attributes: { filename: "cat.png", url: "https://cdn.test/x.png", ...attributes },
        relationships: { tags: { data: [{ type: "tag", id: "t1" }] } },
        meta: { processing },
      },
    },
  };
}

describe("uploadMedia", () => {
  it("POSTs multipart to /api/media with the file and metadata", async () => {
    const stub = stubFetch(created({ alt: "A cat" }));
    const file = new File([new Uint8Array([1, 2, 3])], "cat.png", { type: "image/png" });

    const item = await client(stub).uploadMedia(file, {
      alt: "A cat",
      decorative: false,
      focalX: 0.25,
      tagIds: ["t1", "t2"],
    });

    const call = stub.calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url.pathname).toBe("/api/media");
    expect(call.headers.authorization).toBe("Bearer kiln_rw");
    // fetch sets the multipart boundary itself — a hand-set content-type
    // would lose it.
    expect(call.headers["content-type"]).toBeUndefined();

    const form = call.body as FormData;
    expect(form).toBeInstanceOf(FormData);
    expect((form.get("file") as File).name).toBe("cat.png");
    expect(form.get("alt")).toBe("A cat");
    expect(form.get("decorative")).toBe("false");
    expect(form.get("focal_x")).toBe("0.25");
    expect(form.getAll("tag_ids[]")).toEqual(["t1", "t2"]);

    expect(item.id).toBe("m1");
    expect(item.alt).toBe("A cat");
    expect(item.relationships.tags).toEqual([{ type: "tag", id: "t1" }]);
    expect(item.processing).toBe(false);
  });

  it("names a bare Blob by the filename option", async () => {
    const stub = stubFetch(created());
    await client(stub).uploadMedia(new Blob(["x"]), { filename: "notes.pdf" });
    expect(((stub.calls[0]!.body as FormData).get("file") as File).name).toBe("notes.pdf");
  });

  it("surfaces an A/V upload whose strip is pending as processing", async () => {
    const stub = stubFetch(created({}, true));
    const item = await client(stub).uploadMedia(new Blob(["x"]));
    expect(item.processing).toBe(true);
  });

  it("throws KilnHttpError with the refusal's code", async () => {
    const stub = stubFetch({
      status: 403,
      body: { errors: [{ status: "403", code: "forbidden", detail: "no" }] },
    });

    const error = await client(stub)
      .uploadMedia(new Blob(["x"]))
      .catch((caught: unknown) => caught);

    expect(isKilnHttpError(error)).toBe(true);
    expect(error).toMatchObject({ status: 403, body: { errors: [{ code: "forbidden" }] } });
  });
});

describe("importMediaFromUrl", () => {
  it("POSTs JSON to /api/media/import-url", async () => {
    const stub = stubFetch(created());

    await client(stub).importMediaFromUrl("https://example.com/cat.png", {
      filename: "cat.png",
      caption: "Imported",
      focalY: 0.8,
    });

    const call = stub.calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url.pathname).toBe("/api/media/import-url");
    expect(call.headers["content-type"]).toBe("application/json");
    expect(call.body).toEqual({
      url: "https://example.com/cat.png",
      filename: "cat.png",
      caption: "Imported",
      focal_y: 0.8,
    });
  });
});

describe("updateMedia", () => {
  it("PATCHes the JSON:API media-items route with wire-named attributes", async () => {
    const stub = stubFetch({ body: created({ alt: "New" }).body });

    const item = await client(stub).updateMedia("m1", {
      alt: "New",
      focalX: 0.1,
      addTagIds: ["t3"],
      removeTagIds: ["t1"],
    });

    const call = stub.calls[0]!;
    expect(call.method).toBe("PATCH");
    expect(call.url.pathname).toBe("/api/json/media-items/m1");
    expect(call.headers["content-type"]).toBe("application/vnd.api+json");
    expect(call.body).toEqual({
      data: {
        type: "media_item",
        id: "m1",
        attributes: { alt: "New", focal_x: 0.1, add_tag_ids: ["t3"], remove_tag_ids: ["t1"] },
      },
    });
    expect(item.alt).toBe("New");
  });
});

describe("direct uploads", () => {
  it("uploadMediaDirect begins, PUTs to the presigned URL without Kiln credentials, completes", async () => {
    const stub = stubFetch(
      {
        status: 201,
        body: {
          data: {
            token: "tok",
            upload_url:
              "https://bucket.example.com/private/direct-uploads/abc?X-Amz-Signature=s",
            method: "PUT",
            headers: { "content-length": "3" },
            expires_at: "2026-09-19T12:15:00Z",
            max_bytes: 500000000,
          },
        },
      },
      { status: 200, text: "" },
      created({ alt: "Big" }),
    );

    const file = new File([new Uint8Array([1, 2, 3])], "big.mp4");
    const item = await client(stub).uploadMediaDirect(file, { alt: "Big" });

    const [begin, put, complete] = stub.calls;

    expect(begin!.url.pathname).toBe("/api/media/uploads");
    expect(begin!.body).toEqual({ filename: "big.mp4", byte_size: 3 });

    expect(put!.method).toBe("PUT");
    expect(put!.url.host).toBe("bucket.example.com");
    expect(put!.headers).toEqual({ "content-length": "3" });
    expect(put!.body).toBe(file);

    expect(complete!.url.pathname).toBe("/api/media/uploads/complete");
    expect(complete!.body).toEqual({ token: "tok", alt: "Big" });

    expect(item.alt).toBe("Big");
  });

  it("stops at a failed PUT rather than completing", async () => {
    const stub = stubFetch(
      {
        status: 201,
        body: {
          data: {
            token: "tok",
            upload_url: "https://bucket.example.com/x",
            method: "PUT",
            headers: { "content-length": "1" },
            expires_at: "2026-09-19T12:15:00Z",
            max_bytes: 1,
          },
        },
      },
      { status: 403, text: "SignatureDoesNotMatch" },
    );

    await expect(client(stub).uploadMediaDirect(new Blob(["x"]))).rejects.toMatchObject({
      status: 403,
    });
    expect(stub.calls).toHaveLength(2);
  });
});
