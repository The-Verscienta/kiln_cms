// @ts-check
//
// The browser CSP's `connect-src` is `'self'` alone (#1615; threat-model
// residual 12). It used to be `'self' ws: wss:`, which let a page open a
// websocket to ANY host. Dropping `ws: wss:` rests on one claim a unit test
// cannot check: that CSP3's `'self'` admits `ws:`/`wss:` to the page's own
// host and port, so every socket Kiln opens still connects. This drives a real
// browser through each of them and fails on any CSP violation:
//
//   * `/live` — the console (sign-in, overview, content list, an editor) and
//     the socket's LiveView join (`phx-connected`);
//   * `/ws/gql` and `/ws/collab` — opened by hand, since neither is on a page
//     by default (collab is behind `:collab_prototype`; nothing in the bundle
//     speaks GraphQL over the socket);
//   * a public delivery page, which has no LiveView but loads the same bundle;
//   * the same page served from a second host name (127.0.0.1 rather than
//     localhost) — the custom-domain shape: `'self'` is whatever host served
//     the page, not the configured endpoint host.
//
// And the negative, which is the point of the change: a socket to a DIFFERENT
// origin — a real, reachable Kiln socket on the other host name — is refused
// by the browser with a `connect-src` violation. Under the old policy it
// opened.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

// Recorded from the first byte of every document, before app.js runs.
async function recordViolations(page) {
  await page.addInitScript(() => {
    // @ts-ignore
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (e) => {
      // @ts-ignore
      window.__cspViolations.push({
        directive: e.effectiveDirective,
        blocked: e.blockedURI,
        source: e.sourceFile,
      });
    });
  });

  const consoleHits = [];
  page.on("console", (msg) => {
    if (/Content Security Policy/i.test(msg.text())) consoleHits.push(msg.text());
  });
  return consoleHits;
}

// @ts-ignore
const violations = (page) => page.evaluate(() => window.__cspViolations);

async function expectNoViolations(page, consoleHits) {
  expect(await violations(page)).toEqual([]);
  expect(consoleHits).toEqual([]);
}

// Opens a websocket from inside the page and reports how it ended.
function openSocket(page, url) {
  return page.evaluate(
    (target) =>
      new Promise((resolve) => {
        let ws;
        try {
          ws = new WebSocket(target);
        } catch (e) {
          // Older engines refuse a CSP-blocked socket synchronously.
          resolve(`threw: ${e.name}`);
          return;
        }
        const done = (how) => {
          try {
            ws.close();
          } catch (_e) {}
          resolve(how);
        };
        ws.onopen = () => done("open");
        ws.onerror = () => done("error");
        setTimeout(() => done("timeout"), 5_000);
      }),
    url,
  );
}

const sameOriginSocket = (page, path) =>
  page.evaluate((p) => `${location.origin.replace(/^http/, "ws")}${p}`, path);

test.describe("CSP connect-src 'self' (#1615)", () => {
  test("the console's LiveView connects with connect-src 'self' and no violation", async ({
    page,
  }) => {
    const consoleHits = await recordViolations(page);

    const response = await page.goto("/sign-in");
    const policy = response?.headers()["content-security-policy"] || "";
    expect(policy).toMatch(/(^|;\s*)connect-src 'self'(;|$)/);

    await signInAsAdmin(page);
    await expectNoViolations(page, consoleHits);

    // The content list, then the first editor it links to — the editor is the
    // heaviest LiveView (TipTap, uploads, autosave), and full loads each
    // re-join `/live`.
    await page.goto("/editor");
    await expect(page.locator("[data-phx-main].phx-connected")).toHaveCount(1);
    const editLink = page.locator('a[href^="/editor/content/"]').first();
    const href = await editLink.getAttribute("href");
    expect(href).toBeTruthy();
    await page.goto(/** @type {string} */ (href));
    await expect(page.locator("[data-phx-main].phx-connected")).toHaveCount(1);
    await expect(page.locator('form[id$="-editor"]')).toBeVisible();

    await page.goto("/media");
    await expect(page.locator("[data-phx-main].phx-connected")).toHaveCount(1);

    await expectNoViolations(page, consoleHits);
  });

  test("/ws/gql and /ws/collab are admitted by 'self'", async ({ page }) => {
    const consoleHits = await recordViolations(page);
    await page.goto("/sign-in");

    // GraphQL accepts an anonymous connect.
    const gql = await sameOriginSocket(page, "/ws/gql/websocket?vsn=2.0.0");
    expect(await openSocket(page, gql)).toBe("open");

    // Collab refuses a connect without a token, so the handshake fails — but
    // at the SERVER, after the browser allowed it. A CSP block would show up
    // as a violation below; a server refusal does not.
    const collab = await sameOriginSocket(page, "/ws/collab/websocket?vsn=2.0.0");
    expect(await openSocket(page, collab)).not.toBe("timeout");

    await expectNoViolations(page, consoleHits);
  });

  test("a public page loads with no violation", async ({ page }) => {
    const consoleHits = await recordViolations(page);
    const response = await page.goto("/");
    expect(response?.status()).toBe(200);
    expect(response?.headers()["content-security-policy"] || "").toMatch(
      /(^|;\s*)connect-src 'self'( |;|$)/,
    );
    await expectNoViolations(page, consoleHits);
  });

  test("'self' follows the host that served the page (custom-domain shape)", async ({
    page,
    baseURL,
  }) => {
    const other = /** @type {string} */ (baseURL).replace("localhost", "127.0.0.1");
    test.skip(other === baseURL, "needs a localhost baseURL to derive a second host name");

    const consoleHits = await recordViolations(page);
    await page.goto(`${other}/sign-in`);
    await waitForLiveConnected(page);
    await expect(page.locator("[data-phx-main].phx-connected")).toHaveCount(1);
    await expectNoViolations(page, consoleHits);
  });

  test("a socket to another origin is refused by connect-src", async ({ page, baseURL }) => {
    const other = /** @type {string} */ (baseURL).replace("localhost", "127.0.0.1");
    test.skip(other === baseURL, "needs a localhost baseURL to derive a second host name");

    await recordViolations(page);
    await page.goto("/sign-in");

    // A real, reachable Kiln socket — on a different host name, so a
    // different origin. `ws: wss:` admitted it; `'self'` must not.
    const foreign = `${other.replace(/^http/, "ws")}/ws/gql/websocket?vsn=2.0.0`;
    expect(await openSocket(page, foreign)).not.toBe("open");

    await expect
      .poll(async () => (await violations(page)).map((v) => v.directive))
      .toContain("connect-src");
  });
});
