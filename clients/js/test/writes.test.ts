import { describe, expect, it } from "vitest";

import {
  createClient,
  isKilnError,
  isKilnHttpError,
  KilnAuthError,
  KilnConfigError,
  KilnConflictError,
  KilnError,
  KilnGraphQLError,
  KilnHttpError,
  KilnNetworkError,
  KilnNotFoundError,
  KilnRateLimitError,
  KilnServerError,
  KilnValidationError,
} from "../src/index.js";
import { stubFetch, type FetchStub } from "./helpers.js";

const KEY = "kiln_write_secret";

// `null` = no key at all. `undefined` cannot mean that here: passed to a
// defaulted parameter it gets the default back, and the test exercises the
// keyed path instead.
function client(stub: FetchStub, apiKey: string | null = KEY) {
  return createClient({
    baseUrl: "https://cms.example.com",
    fetch: stub.fetchImpl,
    ...(apiKey === null ? {} : { apiKey }),
  });
}

function postDoc(attributes: Record<string, unknown> = {}, id = "p1") {
  return { data: { id, type: "post", attributes, relationships: {} } };
}

async function caught(promise: Promise<unknown>): Promise<unknown> {
  return promise.then(
    () => {
      throw new Error("expected a rejection");
    },
    (error: unknown) => error,
  );
}

describe("create", () => {
  it("POSTs a JSON:API resource object with the key and flattens the answer", async () => {
    const stub = stubFetch({
      status: 201,
      body: postDoc({ title: "Via SDK", state: "draft" }),
    });

    const post = await client(stub).create("posts", { title: "Via SDK", slug: "via-sdk" });

    const call = stub.calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url.pathname).toBe("/api/json/posts");
    expect(call.headers.accept).toBe("application/vnd.api+json");
    expect(call.headers["content-type"]).toBe("application/vnd.api+json");
    expect(call.headers.authorization).toBe(`Bearer ${KEY}`);
    // No `id` on a create: the server's schema rejects one.
    expect(call.body).toEqual({
      data: { type: "post", attributes: { title: "Via SDK", slug: "via-sdk" } },
    });

    expect(post.id).toBe("p1");
    expect(post.title).toBe("Via SDK");
    expect(post.state).toBe("draft");
  });

  it("derives entry from entries, and honours an explicit type", async () => {
    const stub = stubFetch({ status: 201, body: { data: { id: "e1", type: "entry" } } });
    const kiln = client(stub);

    await kiln.create("entries", { title: "Doc", type_definition_id: "td1" });
    await kiln.create("people", { title: "Ada" }, { type: "person" });
    await kiln.create("pages", { title: "About" });

    expect((stub.calls[0]!.body as { data: { type: string } }).data.type).toBe("entry");
    expect((stub.calls[1]!.body as { data: { type: string } }).data.type).toBe("person");
    expect((stub.calls[2]!.body as { data: { type: string } }).data.type).toBe("page");
  });
});

describe("update", () => {
  it("PATCHes /:id with the id in both the path and the resource object", async () => {
    const stub = stubFetch({ body: postDoc({ title: "Edited" }, "a/b") });

    const post = await client(stub).update("posts", "a/b", { add_tag_ids: ["t1"] });

    const call = stub.calls[0]!;
    expect(call.method).toBe("PATCH");
    expect(call.url.pathname).toBe("/api/json/posts/a%2Fb");
    expect(call.body).toEqual({
      data: { type: "post", id: "a/b", attributes: { add_tag_ids: ["t1"] } },
    });
    expect(post.title).toBe("Edited");
  });
});

describe("workflow transitions", () => {
  it.each([
    ["submitForReview", "submit-for-review"],
    ["returnToDraft", "return-to-draft"],
    ["publish", "publish"],
    ["unpublish", "unpublish"],
  ] as const)("%s PATCHes /:id/%s with an empty resource object", async (method, route) => {
    const stub = stubFetch({ body: postDoc({ state: "whatever" }) });

    const post = await client(stub)[method]("posts", "p1");

    const call = stub.calls[0]!;
    expect(call.method).toBe("PATCH");
    expect(call.url.pathname).toBe(`/api/json/posts/p1/${route}`);
    expect(call.headers["content-type"]).toBe("application/vnd.api+json");
    expect(call.body).toEqual({ data: { type: "post", id: "p1", attributes: {} } });
    expect(post.id).toBe("p1");
  });

  it("transition() kebab-cases any verb, so a newer server's verb is reachable", async () => {
    const stub = stubFetch({ body: postDoc() });
    await client(stub).transition("entries", "e1", "some_new_verb");
    expect(stub.calls[0]!.url.pathname).toBe("/api/json/entries/e1/some-new-verb");
    expect((stub.calls[0]!.body as { data: { type: string } }).data.type).toBe("entry");
  });

  it("a wrong-state transition is a KilnConflictError carrying the current state", async () => {
    const stub = stubFetch({
      status: 409,
      body: {
        errors: [
          {
            status: "409",
            code: "invalid_state_transition",
            detail: "cannot publish: already published",
            meta: { current_state: "published" },
          },
        ],
      },
    });

    const error = await caught(client(stub).publish("posts", "p1"));

    expect(error).toBeInstanceOf(KilnConflictError);
    const conflict = error as KilnConflictError;
    expect(conflict.status).toBe(409);
    expect(conflict.code).toBe("invalid_state_transition");
    expect(conflict.currentState).toBe("published");
    expect(conflict.message).toContain("already published");
  });
});

describe("delete", () => {
  it("DELETEs /:id with no body and resolves on a 200 document", async () => {
    const stub = stubFetch({ body: postDoc() });
    await expect(client(stub).delete("posts", "p1")).resolves.toBeUndefined();

    const call = stub.calls[0]!;
    expect(call.method).toBe("DELETE");
    expect(call.url.pathname).toBe("/api/json/posts/p1");
    expect(call.body).toBeUndefined();
    expect(call.headers["content-type"]).toBeUndefined();
  });

  it("resolves on an empty 204", async () => {
    const stub = stubFetch({ status: 204, text: "" });
    await expect(client(stub).delete("posts", "p1")).resolves.toBeUndefined();
  });
});

describe("the no-API-key guard", () => {
  it.each([
    ["create", (kiln: ReturnType<typeof client>) => kiln.create("posts", { title: "x" })],
    ["update", (kiln: ReturnType<typeof client>) => kiln.update("posts", "p1", {})],
    [
      "transition",
      (kiln: ReturnType<typeof client>) => kiln.transition("posts", "p1", "publish"),
    ],
    ["publish", (kiln: ReturnType<typeof client>) => kiln.publish("posts", "p1")],
    ["delete", (kiln: ReturnType<typeof client>) => kiln.delete("posts", "p1")],
  ])("%s fails fast with KilnConfigError and sends nothing", async (_name, call) => {
    for (const apiKey of [null, ""]) {
      const stub = stubFetch({ body: postDoc() });
      const error = await caught(call(client(stub, apiKey)));

      expect(error).toBeInstanceOf(KilnConfigError);
      expect(isKilnError(error)).toBe(true);
      expect(isKilnHttpError(error)).toBe(false);
      expect((error as KilnConfigError).code).toBe("missing_api_key");
      expect((error as Error).message).toContain("apiKey");
      expect(stub.calls).toHaveLength(0);
    }
  });

  it("reads still work without a key", async () => {
    const stub = stubFetch({ body: { data: [] } });
    await client(stub, null).list("posts");
    expect(stub.calls).toHaveLength(1);
  });
});

describe("error mapping", () => {
  it.each([
    [401, KilnAuthError],
    [403, KilnAuthError],
    [404, KilnNotFoundError],
    [400, KilnValidationError],
    [422, KilnValidationError],
    [409, KilnConflictError],
    [429, KilnRateLimitError],
    [500, KilnServerError],
    [503, KilnServerError],
    [418, KilnHttpError],
  ] as const)("%i → %o, still a KilnHttpError", async (status, klass) => {
    const stub = stubFetch({ status, body: { errors: [{ code: "c", detail: "d" }] } });
    const error = await caught(client(stub).update("posts", "p1", {}));

    expect(error).toBeInstanceOf(klass);
    expect(error).toBeInstanceOf(KilnHttpError);
    expect(error).toBeInstanceOf(KilnError);
    const http = error as KilnHttpError;
    expect(http.status).toBe(status);
    expect(http.code).toBe("c");
    expect(http.url).toBe("https://cms.example.com/api/json/posts/p1");
    expect(http.errors).toEqual([{ code: "c", detail: "d" }]);
  });

  it("reads map through the same hierarchy (backward compatible: KilnHttpError, status, body)", async () => {
    const stub = stubFetch({ status: 404, body: { errors: [{ code: "not_found" }] } });
    const error = await caught(client(stub).list("posts"));

    expect(error).toBeInstanceOf(KilnNotFoundError);
    expect(isKilnHttpError(error)).toBe(true);
    expect((error as KilnHttpError).body).toEqual({ errors: [{ code: "not_found" }] });
  });

  it("a validation error exposes the field pointers", async () => {
    const stub = stubFetch({
      status: 400,
      body: {
        errors: [
          {
            code: "invalid_attribute",
            detail: "has already been taken",
            source: { pointer: "/data/attributes/slug" },
          },
          {
            code: "required",
            detail: "is required",
            source: { pointer: "/data/attributes/title" },
          },
          { code: "invalid_body", detail: "no pointer here" },
        ],
      },
    });

    const error = (await caught(client(stub).create("posts", {}))) as KilnValidationError;

    expect(error).toBeInstanceOf(KilnValidationError);
    expect(error.pointers).toEqual(["/data/attributes/slug", "/data/attributes/title"]);
    expect(error.fieldErrors()).toEqual({
      slug: ["has already been taken"],
      title: ["is required"],
    });
  });

  it("a 429 carries Retry-After as seconds", async () => {
    const stub = stubFetch({
      status: 429,
      headers: { "retry-after": "42" },
      body: { errors: [{ status: "429", code: "too_many_requests" }] },
    });

    const error = (await caught(client(stub).create("posts", {}))) as KilnRateLimitError;

    expect(error).toBeInstanceOf(KilnRateLimitError);
    expect(error.retryAfter).toBe(42);
    expect(error.code).toBe("too_many_requests");
  });

  it("an HTTP-date Retry-After becomes seconds from now", async () => {
    const at = new Date(Date.now() + 30_000).toUTCString();
    const stub = stubFetch({ status: 503, headers: { "retry-after": at }, body: {} });

    const error = (await caught(client(stub).publish("posts", "p1"))) as KilnServerError;

    expect(error.retryAfter).toBeGreaterThanOrEqual(28);
    expect(error.retryAfter).toBeLessThanOrEqual(31);
  });

  it("a fetch that throws becomes KilnNetworkError with the cause kept", async () => {
    const cause = new TypeError("fetch failed");
    const stub = stubFetch({ throws: cause });

    const error = (await caught(client(stub).create("posts", {}))) as KilnNetworkError;

    expect(error).toBeInstanceOf(KilnNetworkError);
    expect(error.code).toBe("network_error");
    expect(error.cause).toBe(cause);
    expect(error.status).toBeUndefined();
  });

  it("an abort is passed through untouched, not wrapped", async () => {
    const abort = new DOMException("The operation was aborted.", "AbortError");
    const stub = stubFetch({ throws: abort });

    expect(await caught(client(stub).list("posts"))).toBe(abort);
  });

  it("never puts the API key in an error", async () => {
    const stub = stubFetch({ status: 401, body: { errors: [{ code: "unauthorized" }] } });
    const error = (await caught(client(stub).create("posts", {}))) as KilnAuthError;

    expect(JSON.stringify({ ...error, message: error.message })).not.toContain(KEY);
    expect(String(error)).not.toContain(KEY);
  });
});

describe("graphql", () => {
  const QUERY =
    "query ($slug: String!, $locale: String!) { postBySlug(slug: $slug, locale: $locale) { title } }";

  it("POSTs {query, variables} to /gql as plain JSON and resolves to data", async () => {
    const stub = stubFetch({ body: { data: { postBySlug: { title: "Hi" } } } });

    const data = await client(stub).graphql<{ postBySlug: { title: string } }>(QUERY, {
      slug: "hi",
    });

    const call = stub.calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url.pathname).toBe("/gql");
    expect(call.headers["content-type"]).toBe("application/json");
    expect(call.headers.accept).toBe("application/json");
    expect(call.headers.authorization).toBe(`Bearer ${KEY}`);
    expect(call.body).toEqual({ query: QUERY, variables: { slug: "hi" } });
    expect(data.postBySlug.title).toBe("Hi");
  });

  it("needs no key, and forwards operationName", async () => {
    const stub = stubFetch({ body: { data: {} } });
    await client(stub, null).graphql(
      "query A { a } query B { b }",
      {},
      {
        operationName: "B",
      },
    );

    expect(stub.calls[0]!.headers.authorization).toBeUndefined();
    expect(stub.calls[0]!.body).toMatchObject({ operationName: "B" });
  });

  it("top-level errors throw KilnGraphQLError with the partial data", async () => {
    const stub = stubFetch({
      body: {
        data: { postBySlug: null },
        errors: [{ message: "forbidden", path: ["postBySlug"], code: "forbidden" }],
      },
    });

    const error = (await caught(
      client(stub).graphql(QUERY, { slug: "x" }),
    )) as KilnGraphQLError;

    expect(error).toBeInstanceOf(KilnGraphQLError);
    expect(error.code).toBe("forbidden");
    expect(error.status).toBe(200);
    expect(error.graphqlErrors[0]!.path).toEqual(["postBySlug"]);
    expect(error.data).toEqual({ postBySlug: null });
    expect(error.message).toContain("forbidden");
  });

  it("reads the code from extensions when that is where it is", async () => {
    const stub = stubFetch({
      body: { errors: [{ message: "nope", extensions: { code: "invalid_state_transition" } }] },
    });
    const error = (await caught(client(stub).graphql("{ a }"))) as KilnGraphQLError;
    expect(error.code).toBe("invalid_state_transition");
    expect(error.data).toBeNull();
  });

  it("a GraphQL-shaped 400 (unparseable document) is a KilnGraphQLError", async () => {
    const stub = stubFetch({ status: 400, body: { errors: [{ message: "syntax error" }] } });
    const error = (await caught(client(stub).graphql("{"))) as KilnGraphQLError;
    expect(error).toBeInstanceOf(KilnGraphQLError);
    expect(error.status).toBe(400);
  });

  it("transport refusals keep their HTTP class (429 is still a rate limit)", async () => {
    const stub = stubFetch({ status: 429, headers: { "retry-after": "5" }, body: {} });
    const error = (await caught(client(stub).graphql("{ a }"))) as KilnRateLimitError;
    expect(error).toBeInstanceOf(KilnRateLimitError);
    expect(error.retryAfter).toBe(5);
  });

  it("mutation payload errors are data, not a throw", async () => {
    // Ash reports a refused mutation inside the payload; the helper must not
    // invent a failure the caller did not ask it to detect.
    const payload = { createPost: { result: null, errors: [{ message: "forbidden" }] } };
    const stub = stubFetch({ body: { data: payload } });
    expect(await client(stub).graphql("mutation { createPost }")).toEqual(payload);
  });
});
