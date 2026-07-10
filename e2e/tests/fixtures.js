// @ts-check
//
// Shared Playwright fixtures. Import `test`/`expect` from here rather than from
// `@playwright/test` directly, so every spec picks up the LiveView navigation
// guard below.
const base = require("@playwright/test");

// Wait until a freshly loaded LiveView has actually connected its socket.
//
// Once app.js loads, LiveView binds the page's phx-click / phx-submit controls
// and *suppresses* their native fallback (e.g. the sign-in form's plain POST).
// A click landing in the window after JS has bound but before the channel has
// joined is swallowed and never reaches the server — the page just sits there.
// Locally the socket joins in milliseconds so this is invisible; on a cold CI
// runner the join lags the first interaction and the click is lost.
//
// `data-phx-main` is rendered server-side on the main view's container, so its
// absence means this page has no LiveView at all (the public content pages are
// plain controller routes). Those never connect a socket, so waiting on one
// would hang — return immediately instead.
async function waitForLiveConnected(page) {
  await page.waitForFunction(() => {
    if (!document.querySelector("[data-phx-main]")) return true;
    return Boolean(window.liveSocket && window.liveSocket.isConnected());
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
