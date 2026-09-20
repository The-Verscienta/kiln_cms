import { describe, expect, it } from "vitest";

import { verifyWebhook } from "../src/index.js";

// The same vector `KilnCMS.WebhooksTest` and the Elixir client assert, so the
// three implementations cannot drift apart unnoticed.
const secret = "whsec-test";
const body = '{"event":"page.published","delivery_id":"d-1","data":{}}';
const v1 = "e09a0895dc1b7f726710de36079d36941c634959f61a2c547ff00e848c3df80a";
const header = `t=1800000000,v1=${v1}`;
const now = 1_800_000_000;

describe("verifyWebhook", () => {
  it("accepts the server's signature inside the window", async () => {
    expect(await verifyWebhook(secret, body, header, { now })).toEqual({ ok: true });
    expect(await verifyWebhook(secret, body, header, { now: now + 300 })).toEqual({ ok: true });
    expect(
      await verifyWebhook(secret, new TextEncoder().encode(body), header, { now }),
    ).toEqual({
      ok: true,
    });
  });

  it("refuses a stale or future timestamp", async () => {
    expect(await verifyWebhook(secret, body, header, { now: now + 301 })).toEqual({
      ok: false,
      reason: "expired",
    });
    expect(await verifyWebhook(secret, body, header, { now: now - 301 })).toEqual({
      ok: false,
      reason: "expired",
    });
    expect(
      await verifyWebhook(secret, body, header, { now: now + 900, toleranceSeconds: 900 }),
    ).toEqual({ ok: true });
  });

  it("refuses a changed body, a wrong secret, and a re-stamped capture", async () => {
    const mismatch = { ok: false, reason: "mismatch" };
    expect(await verifyWebhook(secret, body + " ", header, { now })).toEqual(mismatch);
    expect(await verifyWebhook("other", body, header, { now })).toEqual(mismatch);
    expect(await verifyWebhook(secret, body, `t=1800000100,v1=${v1}`, { now })).toEqual(
      mismatch,
    );
  });

  it("accepts any matching v1 among several", async () => {
    const rolled = `t=1800000000,v1=${"0".repeat(64)},v1=${v1}`;
    expect(await verifyWebhook(secret, body, rolled, { now })).toEqual({ ok: true });
  });

  it("calls a header that does not parse malformed", async () => {
    for (const bad of [null, undefined, "", "v1=abc", "t=soon,v1=abc", "t=1,t=2,v1=a", "t=1"]) {
      expect(await verifyWebhook(secret, body, bad, { now })).toEqual({
        ok: false,
        reason: "malformed",
      });
    }
  });
});
