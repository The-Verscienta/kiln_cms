// @ts-check
//
// Shared Playwright fixtures. Import `test`/`expect` from here rather than from
// `@playwright/test` directly, so every spec picks up the LiveView navigation
// guard below.
const base = require("@playwright/test");

// Wait until a freshly loaded LiveView has actually *joined* its channel.
//
// Once app.js loads, LiveView binds the page's phx-click / phx-submit controls
// and *suppresses* their native fallback (e.g. the sign-in form's plain POST).
// Every event push then goes through `channel.canPush()`, which requires the
// view's channel join to be acked — not merely the WebSocket transport to be
// open. An event fired in the window between "socket connected" and "join
// complete" is rejected client-side and never reaches the server — the page
// just sits there. Locally the join acks in milliseconds so this is invisible;
// on a cold CI runner the server's first connected mount lags the transport by
// long enough that the suite's first click lands in that window (the
// sign-in-stays-on-/sign-in flake). So wait for `phx-connected` on the main
// container — LiveView adds that class only once the join has completed —
// rather than `liveSocket.isConnected()`, which is transport-level and true
// while the join is still pending.
//
// `data-phx-main` is rendered server-side on the main view's container, so its
// absence means this page has no LiveView at all (the public content pages are
// plain controller routes). Those never connect a socket, so waiting on one
// would hang — return immediately instead.
async function waitForLiveConnected(page) {
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    if (!main) return true;
    return main.classList.contains("phx-connected");
  });
}

// Wrap the navigation methods so the guard runs after every full page load.
// In-app live navigation (phx-click → push_navigate) reuses the already-
// connected socket, so only full loads need it.
const test = base.test.extend({
  page: async ({ page }, use) => {
    for (const method of ["goto", "reload"]) {
      const navigate = page[method].bind(page);
      page[method] = async (...args) => {
        const response = await navigate(...args);
        await waitForLiveConnected(page);
        return response;
      };
    }
    await use(page);
  },
});

module.exports = { test, expect: base.expect, waitForLiveConnected };
