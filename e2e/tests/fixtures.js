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

// ── Shared journey helpers ──────────────────────────────────────────────────
// Here rather than copied into each spec: `addBlock`'s `:visible` filter and
// `newDraftPage`'s dropdown fallback were both worked out the hard way, and a
// second copy is a second thing to forget to update.

// Demo admin seeded by priv/repo/seeds.exs (mix e2e.setup).
const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

async function signInAsAdmin(page) {
  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();
  // Editors/admins land on the console overview by default after sign-in
  // (#157); this seeded user has the :admin role (see priv/repo/seeds.exs).
  await base.expect(page).toHaveURL("/editor/overview");
}

// Start a fresh draft page from the editor index (the `new` handler creates an
// "Untitled …" draft and navigates into the editor). Past
// @max_inline_new_buttons content types the per-type "New …" buttons collapse
// into the #content-new-menu <details> dropdown, so open it first.
async function newDraftPage(page) {
  await page.goto("/editor");
  const newMenu = page.locator("#content-new-menu summary");
  if (await newMenu.count()) await newMenu.click();
  await page.click('button[phx-click="new"][phx-value-kind="page"]');
  await page.waitForURL(/\/editor\/(content\/page|pages)\//);
  await base.expect(page.locator('form[id$="-editor"]')).toBeVisible();
}

// The block inserter (#29) is a closed dropdown: its options only become
// visible/clickable after the "Add block" trigger opens the menu (the
// BlockInserter JS hook toggles `data-inserter-menu`'s `hidden` attribute).
// Selecting an option closes the menu again, so each insert needs its own
// trigger click.
//
// Once a block exists there are several inserters (the inline "+" between-block
// inserters from themes B2/C/D), each rendering a hidden add_block option per
// type — so a bare phx-value-type match resolves to multiple elements and can
// click a hidden one. Open the unique main "Add block" menu and click the
// *visible* option instead.
async function addBlock(page, type) {
  await page.getByRole("button", { name: /add block/i }).click();
  await page
    .locator(`button[data-inserter-item][phx-value-type="${type}"]:visible`)
    .first()
    .click();
}

module.exports = {
  test,
  expect: base.expect,
  waitForLiveConnected,
  ADMIN,
  signInAsAdmin,
  newDraftPage,
  addBlock,
};
