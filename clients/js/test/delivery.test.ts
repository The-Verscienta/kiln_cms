import { describe, expect, it } from "vitest";

import { createClient, KilnNotFoundError, KilnValidationError } from "../src/index.js";
import { stubFetch, type FetchStub } from "./helpers.js";

function client(stub: FetchStub, apiKey?: string) {
  return createClient({ baseUrl: "https://cms.example.com", fetch: stub.fetchImpl, apiKey });
}

describe("resolvePath", () => {
  it("returns an ok verdict and sends the locale trio", async () => {
    const verdict = {
      status: "ok",
      type: "post",
      slug: "hello",
      id: "p1",
      path: "/blog/hello",
      locale: "fr",
    };
    const stub = stubFetch({ body: verdict });

    const result = await client(stub).resolvePath("/blog/hello", {
      locale: "fr-CA",
      fallback: false,
      fallbackLocale: "en",
    });

    expect(result).toEqual(verdict);
    const url = stub.calls[0]!.url;
    expect(url.pathname).toBe("/api/resolve");
    expect(url.searchParams.get("path")).toBe("/blog/hello");
    expect(url.searchParams.get("locale")).toBe("fr-CA");
    expect(url.searchParams.get("fallback")).toBe("false");
    expect(url.searchParams.get("fallback_locale")).toBe("en");
    expect(stub.calls[0]!.headers.accept).toBe("application/json");
  });

  it("returns a moved verdict", async () => {
    const stub = stubFetch({ body: { status: "moved", to: "/blog/new" } });
    const result = await client(stub).resolvePath("/blog/old");
    expect(result.status === "moved" && result.to).toBe("/blog/new");
  });

  it("the not_found 404 is a verdict, not a throw", async () => {
    const stub = stubFetch({ status: 404, body: { status: "not_found" } });
    await expect(client(stub).resolvePath("/nothing")).resolves.toEqual({
      status: "not_found",
    });
  });

  it("a 404 without the verdict body still throws", async () => {
    const stub = stubFetch({
      status: 404,
      body: { errors: [{ status: "404", code: "not_found" }] },
    });
    await expect(client(stub).resolvePath("/nothing")).rejects.toBeInstanceOf(
      KilnNotFoundError,
    );
  });

  it("a missing leading slash is the server's 400", async () => {
    const stub = stubFetch({
      status: 400,
      body: { errors: [{ status: "400", code: "missing_path" }] },
    });
    await expect(client(stub).resolvePath("blog/hello")).rejects.toMatchObject({
      name: "KilnValidationError",
      code: "missing_path",
    });
  });
});

describe("menus, menu and locales", () => {
  it("menus lists every menu", async () => {
    const body = { menus: [{ key: "main", name: "Main", locale: "en" }] };
    const stub = stubFetch({ body });
    expect(await client(stub).menus()).toEqual(body);
    expect(stub.calls[0]!.url.pathname).toBe("/api/menus");
  });

  it("menu reads one resolved tree in a locale", async () => {
    const body = { key: "main", name: "Main", locale: "fr", items: [] };
    const stub = stubFetch({ body });
    expect(await client(stub).menu("main", { locale: "fr" })).toEqual(body);
    expect(stub.calls[0]!.url.pathname).toBe("/api/menus/main");
    expect(stub.calls[0]!.url.searchParams.get("locale")).toBe("fr");
  });

  it("locales returns the default, the locales and the chains", async () => {
    const body = { default: "en", locales: ["en", "fr"], fallbacks: { en: [], fr: ["en"] } };
    const stub = stubFetch({ body });
    expect(await client(stub).locales()).toEqual(body);
    expect(stub.calls[0]!.url.pathname).toBe("/api/locales");
  });
});

describe("related", () => {
  it("reads the related documents with limit and locale", async () => {
    const body = { type: "post", slug: "hello", locale: "en", related: [] };
    const stub = stubFetch({ body });

    expect(await client(stub).related("post", "hello", { limit: 3, locale: "en" })).toEqual(
      body,
    );

    const url = stub.calls[0]!.url;
    expect(url.pathname).toBe("/api/content/post/hello/related");
    expect(url.searchParams.get("limit")).toBe("3");
    expect(url.searchParams.get("locale")).toBe("en");
  });
});

describe("form and submitForm", () => {
  it("form reads the schema", async () => {
    const body = { slug: "contact", honeypot_field: "website", fields: [] };
    const stub = stubFetch({ body });
    expect(await client(stub).form("contact")).toEqual(body);
    expect(stub.calls[0]!.url.pathname).toBe("/api/forms/contact");
  });

  it("form passes the new field types and min/max/step through untouched", async () => {
    const field = (type: string, extra = {}) => ({
      name: type,
      label: type,
      type,
      required: false,
      options: [],
      help_text: null,
      placeholder: null,
      default_value: null,
      width: "full",
      min: null,
      max: null,
      step: null,
      ...extra,
    });
    const body = {
      slug: "contact",
      honeypot_field: "website",
      fields: [
        field("checkboxes", { options: ["a", "b"] }),
        field("number", { min: 0, max: 10, step: 0.5 }),
        field("rating", { min: 1, max: 5 }),
      ],
    };
    const got = await client(stubFetch({ body })).form("contact");
    expect(got.fields.map((f) => f.type)).toEqual(["checkboxes", "number", "rating"]);
    expect(got.fields[1]).toMatchObject({ min: 0, max: 10, step: 0.5 });
  });

  it("submitForm sends a checkboxes answer as a JSON array", async () => {
    const stub = stubFetch({ body: { ok: true, message: "Thanks!" } });
    await client(stub).submitForm("contact", { tags: ["a", "b"], stars: 4 });
    expect(stub.calls[0]!.body).toEqual({ tags: ["a", "b"], stars: 4 });
  });

  it("submitForm posts the values as JSON and never sends the client's key", async () => {
    const stub = stubFetch({ body: { ok: true, message: "Thanks!" } });

    const result = await client(stub, "kiln_configured_key").submitForm(
      "contact",
      { email: "a@example.com" },
      { locale: "fr" },
    );

    expect(result).toEqual({ ok: true, message: "Thanks!" });
    const call = stub.calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url.pathname).toBe("/api/forms/contact");
    expect(call.body).toEqual({ email: "a@example.com", locale: "fr" });
    expect(call.headers["content-type"]).toBe("application/json");
    expect(call.headers.authorization).toBeUndefined();
  });

  it("a 422 refusal throws KilnValidationError whose fieldErrors reads the form's map", async () => {
    const stub = stubFetch({
      status: 422,
      body: { ok: false, errors: { email: "is required" } },
    });

    const error = await client(stub)
      .submitForm("contact", {})
      .catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(KilnValidationError);
    expect((error as KilnValidationError).fieldErrors()).toEqual({ email: ["is required"] });
  });

  it("fieldErrors still reads JSON:API pointers", async () => {
    const stub = stubFetch({
      status: 400,
      body: {
        errors: [
          { code: "invalid", detail: "is taken", source: { pointer: "/data/attributes/slug" } },
        ],
      },
    });

    const error = await client(stub, "kiln_key")
      .create("posts", { slug: "x" })
      .catch((caught: unknown) => caught);

    expect((error as KilnValidationError).fieldErrors()).toEqual({ slug: ["is taken"] });
  });
});
