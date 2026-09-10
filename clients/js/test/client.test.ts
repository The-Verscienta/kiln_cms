import { describe, expect, it } from "vitest";

import {
  createClient,
  flattenDocument,
  isKilnHttpError,
  refKey,
  resolve,
  type KilnHttpError,
} from "../src/index.js";
import { emptyDoc, stubFetch } from "./helpers.js";

function client(stub: { fetchImpl: typeof globalThis.fetch }, apiKey?: string) {
  return createClient({ baseUrl: "https://cms.example.com", fetch: stub.fetchImpl, apiKey });
}

describe("list", () => {
  it("reads the /published feed by default and flattens the document", async () => {
    const stub = stubFetch({
      body: {
        data: [
          {
            id: "p1",
            type: "post",
            attributes: { title: "Hello" },
            relationships: {
              tags: { data: [{ type: "tag", id: "t1", meta: {} }] },
              category: { links: {} },
            },
          },
        ],
        included: [{ id: "t1", type: "tag", attributes: { name: "Elixir" } }],
        meta: { page: { total: 41 } },
      },
    });

    const { items, included, total } = await client(stub).list("posts");
    const call = stub.calls[0]!;

    expect(call.url.pathname).toBe("/api/json/posts/published");
    expect(call.url.searchParams.get("page[count]")).toBe("true");

    expect(total).toBe(41);
    const item = items[0]!;
    expect(item.id).toBe("p1");
    expect(item.title).toBe("Hello");
    expect(item.relationships.tags).toEqual([{ type: "tag", id: "t1" }]);
    // A relationship without a "data" key flattens to no refs.
    expect(item.relationships.category).toEqual([]);
    expect(included.get(refKey("tag", "t1"))?.name).toBe("Elixir");

    expect(resolve(item, "tags", included).map((tag) => tag.name)).toEqual(["Elixir"]);
  });

  it("published: false reads the plain (credential-widened) index", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    await client(stub).list("posts", { published: false });
    expect(stub.calls[0]!.url.pathname).toBe("/api/json/posts");
  });

  it("encodes filters, operators, nested relationship filters, sorts and pagination", async () => {
    const stub = stubFetch({ body: emptyDoc() });

    const { total } = await client(stub).list("entries", {
      filter: { type_name: "product", id: { in: ["a", "b"] }, tags: { slug: "sale" } },
      customFilter: { price: { lte: 10 } },
      sort: ["-published_at", "title"],
      customSort: ["-price"],
      include: ["tags", "category"],
      fields: { entry: ["title", "slug"] },
      limit: 5,
      offset: 10,
      count: false,
    });

    expect(total).toBeNull();

    const params = stub.calls[0]!.url.searchParams;
    expect(stub.calls[0]!.url.pathname).toBe("/api/json/entries/published");
    expect(params.get("filter[type_name]")).toBe("product");
    expect(params.getAll("filter[id][in][]")).toEqual(["a", "b"]);
    expect(params.get("filter[tags][slug]")).toBe("sale");
    expect(params.get("custom_filter[price][lte]")).toBe("10");
    expect(params.get("sort")).toBe("-published_at,title");
    expect(params.get("custom_sort")).toBe("-price");
    expect(params.get("include")).toBe("tags,category");
    expect(params.get("fields[entry]")).toBe("title,slug");
    expect(params.get("page[limit]")).toBe("5");
    expect(params.get("page[offset]")).toBe("10");
    expect(params.get("page[count]")).toBeNull();
  });
});

describe("one", () => {
  it("returns the first match with the included lookup merged in", async () => {
    const stub = stubFetch({
      body: {
        data: [{ id: "p1", type: "post", attributes: { slug: "hello" } }],
        included: [{ id: "t1", type: "tag", attributes: { name: "News" } }],
      },
    });

    const item = await client(stub).one("posts", { slug: "hello" });
    const params = stub.calls[0]!.url.searchParams;

    expect(params.get("filter[slug]")).toBe("hello");
    expect(params.get("page[limit]")).toBe("1");
    expect(params.get("page[count]")).toBeNull();
    expect(item?.id).toBe("p1");
    expect(item?.included.get(refKey("tag", "t1"))?.name).toBe("News");
  });

  it("resolves null when nothing matches", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    expect(await client(stub).one("posts", { slug: "nope" })).toBeNull();
  });
});

describe("byIds", () => {
  it("makes no request for an empty id list", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    expect(await client(stub).byIds("posts", [])).toEqual([]);
    expect(stub.calls).toHaveLength(0);
  });

  it("fetches in one request and returns items in ids order, dropping misses", async () => {
    const stub = stubFetch({
      body: {
        data: [
          { id: "b", type: "post", attributes: {} },
          { id: "a", type: "post", attributes: {} },
        ],
      },
    });

    const items = await client(stub).byIds("posts", ["a", "missing", "b"]);
    const params = stub.calls[0]!.url.searchParams;

    expect(params.getAll("filter[id][in][]")).toEqual(["a", "missing", "b"]);
    expect(params.get("page[limit]")).toBe("3");
    expect(items.map((item) => item.id)).toEqual(["a", "b"]);
  });

  it("chunks id lists past the server's 100-row page cap", async () => {
    // 150 ids in one request would be clamped to 100 rows server-side, making
    // the last 50 records indistinguishable from misses.
    const ids = Array.from({ length: 150 }, (_, index) => `id-${index}`);
    const stub = stubFetch({
      body: { data: [{ id: "id-149", type: "post", attributes: {} }] },
    });

    const items = await client(stub).byIds("posts", ids);

    expect(stub.calls).toHaveLength(2);
    expect(stub.calls[0]!.url.searchParams.getAll("filter[id][in][]")).toHaveLength(100);
    expect(stub.calls[1]!.url.searchParams.getAll("filter[id][in][]")).toHaveLength(50);
    expect(stub.calls[1]!.url.searchParams.get("page[limit]")).toBe("50");
    // Ordering still follows `ids`, across chunk boundaries.
    expect(items.map((item) => item.id)).toEqual(["id-149"]);
  });
});

describe("per-type search", () => {
  it("textSearch reads the /search/published twin with facets and options", async () => {
    const stub = stubFetch({ body: emptyDoc() });

    await client(stub).textSearch("posts", "hello", {
      locale: "fr",
      tagIds: ["t1", "t2"],
      customFilter: { badge: "sale" },
      sort: ["-published_at"],
      limit: 5,
      include: ["tags"],
      fields: { post: ["title"] },
    });

    const call = stub.calls[0]!;
    expect(call.url.pathname).toBe("/api/json/posts/search/published");
    const params = call.url.searchParams;
    expect(params.get("query")).toBe("hello");
    expect(params.get("locale")).toBe("fr");
    expect(params.getAll("tag_ids[]")).toEqual(["t1", "t2"]);
    expect(params.get("custom_filter[badge]")).toBe("sale");
    expect(params.get("sort")).toBe("-published_at");
    expect(params.get("page[limit]")).toBe("5");
    expect(params.get("include")).toBe("tags");
    expect(params.get("fields[post]")).toBe("title");
  });

  it("published: false searches the base (draft-widened) route", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    await client(stub).textSearch("posts", "hello", { published: false });
    expect(stub.calls[0]!.url.pathname).toBe("/api/json/posts/search");
  });

  it("semanticSearch and autocomplete hit their published twins", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    const kiln = client(stub);

    await kiln.semanticSearch("posts", "how to fire a kiln");
    await kiln.autocomplete("posts", "welc");

    expect(stub.calls[0]!.url.pathname).toBe("/api/json/posts/semantic-search/published");
    expect(stub.calls[0]!.url.searchParams.get("query")).toBe("how to fire a kiln");
    expect(stub.calls[1]!.url.pathname).toBe("/api/json/posts/autocomplete/published");
    expect(stub.calls[1]!.url.searchParams.get("prefix")).toBe("welc");
  });
});

describe("hybrid search", () => {
  it("encodes the /api/search options and returns the raw response", async () => {
    const stub = stubFetch({ body: { results: { posts: [] }, suggestion: "hello" } });

    const result = await client(stub).search("helo", {
      limit: 5,
      locale: "en",
      category: "news",
      facets: true,
    });

    const call = stub.calls[0]!;
    expect(call.url.pathname).toBe("/api/search");
    expect(call.url.searchParams.get("q")).toBe("helo");
    expect(call.url.searchParams.get("limit")).toBe("5");
    expect(call.url.searchParams.get("category")).toBe("news");
    expect(call.url.searchParams.get("facets")).toBe("true");
    expect(result.suggestion).toBe("hello");
  });
});

describe("artifact", () => {
  it("fetches the fired artifact with surface, locale and as_of", async () => {
    const stub = stubFetch({ body: { type: "post", title: "Hi", slug: "hi", blocks: [] } });

    const doc = await client(stub).artifact("post", "hi", {
      surface: "json_ld",
      locale: "fr",
      asOf: new Date("2026-03-01T09:00:00Z"),
    });

    const call = stub.calls[0]!;
    expect(call.url.pathname).toBe("/api/content/post/hi");
    expect(call.url.searchParams.get("surface")).toBe("json_ld");
    expect(call.url.searchParams.get("locale")).toBe("fr");
    expect(call.url.searchParams.get("as_of")).toBe("2026-03-01T09:00:00.000Z");
    expect(call.headers.accept).toBe("application/json");
    expect(doc.title).toBe("Hi");
  });

  it("passes a string as_of through verbatim (bare dates mean end of day)", async () => {
    const stub = stubFetch({ body: {} });
    await client(stub).artifact("post", "hi", { asOf: "2026-03-01" });
    expect(stub.calls[0]!.url.searchParams.get("as_of")).toBe("2026-03-01");
  });

  it("retries once on a cold-cache 503", async () => {
    const stub = stubFetch(
      { status: 503, body: { error: "cold" } },
      { body: { type: "post", title: "Warm", slug: "hi", blocks: [] } },
    );

    const doc = await client(stub).artifact("post", "hi", { retryDelayMs: 0 });
    expect(stub.calls).toHaveLength(2);
    expect(doc.title).toBe("Warm");
  });

  it("retry: false fails fast on 503", async () => {
    const stub = stubFetch({ status: 503, body: {} });
    await expect(client(stub).artifact("post", "hi", { retry: false })).rejects.toMatchObject({
      status: 503,
    });
    expect(stub.calls).toHaveLength(1);
  });

  it("does not retry a 404", async () => {
    const stub = stubFetch({ status: 404, body: { error: "not_published" } });
    await expect(client(stub).artifact("post", "gone")).rejects.toMatchObject({ status: 404 });
    expect(stub.calls).toHaveLength(1);
  });

  it("a signal aborting during the retry wait surfaces the 503 without retrying", async () => {
    // A caller-bounded call must not overrun its bound sleeping out the retry
    // delay, and the error it sees should be the server's 503, not the
    // AbortError of a doomed second request.
    const stub = stubFetch({ status: 503, body: { error: "cold" } });
    const controller = new AbortController();

    const pending = client(stub).artifact("post", "hi", {
      signal: controller.signal,
      retryDelayMs: 60_000,
    });
    controller.abort();

    await expect(pending).rejects.toMatchObject({ status: 503 });
    expect(stub.calls).toHaveLength(1);
  });
});

describe("contentAsOf", () => {
  it("reads the point-in-time collection index", async () => {
    const stub = stubFetch({
      body: { as_of: "2026-03-01T23:59:59Z", type: "post", entries: [] },
    });

    const result = await client(stub).contentAsOf("post", "2026-03-01", { limit: 50 });

    const call = stub.calls[0]!;
    expect(call.url.pathname).toBe("/api/content/post");
    expect(call.url.searchParams.get("as_of")).toBe("2026-03-01");
    expect(call.url.searchParams.get("limit")).toBe("50");
    expect(result.entries).toEqual([]);
  });
});

describe("preview", () => {
  it("redeems the token at /preview/:token and unwraps the {data} envelope", async () => {
    // The server responds `{"data": {…draft…}}` (preview_controller.ex), not
    // the bare draft — the stub must model that or the test proves nothing.
    const stub = stubFetch({ body: { data: { title: "Draft", blocks: [] } } });

    const draft = await client(stub).preview<{ title: string }>("tok/en+1");

    expect(stub.calls[0]!.url.pathname).toBe("/preview/tok%2Fen%2B1");
    expect(draft.title).toBe("Draft");
  });
});

describe("schema", () => {
  it("fetches /api/schema with type and blocks filters as plain JSON", async () => {
    const stub = stubFetch({ body: { $defs: {} } });

    const doc = await client(stub, "secret-key").schema({
      types: ["post", "page"],
      blocksOnly: true,
    });

    const call = stub.calls[0]!;
    expect(call.url.pathname).toBe("/api/schema");
    expect(call.url.searchParams.get("type")).toBe("post,page");
    expect(call.url.searchParams.get("blocks")).toBe("only");
    expect(call.headers.accept).toBe("application/json");
    expect(call.headers.authorization).toBe("Bearer secret-key");
    expect(doc.$defs).toEqual({});
  });

  it("sends no params by default", async () => {
    const stub = stubFetch({ body: {} });
    await client(stub).schema();
    expect(stub.calls[0]!.url.search).toBe("");
  });
});

describe("flattenDocument", () => {
  it("flattens data: null (empty to-one primary data) to no items", () => {
    // Valid JSON:API for a to-one read with nothing there — must not throw.
    expect(flattenDocument({ data: null })).toEqual({
      items: [],
      included: new Map(),
      total: null,
    });
  });
});

describe("transport", () => {
  it("sends the JSON:API accept header and a bearer key when configured", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    await client(stub, "secret-key").list("posts");

    expect(stub.calls[0]!.headers.accept).toBe("application/vnd.api+json");
    expect(stub.calls[0]!.headers.authorization).toBe("Bearer secret-key");
  });

  it("sends no authorization header without a key", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    await client(stub).list("posts");
    expect(stub.calls[0]!.headers.authorization).toBeUndefined();
  });

  it("trims trailing slashes off the base URL", async () => {
    const stub = stubFetch({ body: emptyDoc() });
    const kiln = createClient({ baseUrl: "https://cms.example.com//", fetch: stub.fetchImpl });
    await kiln.list("posts");
    expect(stub.calls[0]!.url.toString()).toContain(
      "https://cms.example.com/api/json/posts/published",
    );
  });

  it("throws KilnHttpError with the parsed JSON error body", async () => {
    const stub = stubFetch({ status: 422, body: { errors: [{ code: "invalid" }] } });

    const error = await client(stub)
      .list("posts")
      .then(
        () => null,
        (caught: unknown) => caught,
      );

    expect(isKilnHttpError(error)).toBe(true);
    const httpError = error as KilnHttpError;
    expect(httpError.status).toBe(422);
    expect(httpError.body).toEqual({ errors: [{ code: "invalid" }] });
    expect(httpError.url).toContain("/api/json/posts/published");
  });

  it("falls back to raw text for a non-JSON error body", async () => {
    const stub = stubFetch({ status: 500, text: "boom" });
    await expect(client(stub).list("posts")).rejects.toMatchObject({ body: "boom" });
  });
});
