// @ts-check
//
// Shared Playwright fixtures. Import `test`/`expect` from here rather than from
// `@playwright/test` directly, so every spec picks up the LiveView navigation
// guard below.
const base = require("@playwright/test");
const config = require("../playwright.config");

// The same baseURL playwright.config.js resolves for the `page`/`context`
// fixtures — `browser.newContext()` doesn't inherit it (that only happens
// inside @playwright/test's own fixture factory), so `newGuardedContext`
// below has to pass it explicitly or a relative `page.goto("/sign-in")`
// throws "Cannot navigate to invalid URL".
const BASE_URL = config.use.baseURL;

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

// Wrap a page's navigation methods so the guard runs after every full page
// load. In-app live navigation (phx-click → push_navigate) reuses the
// already-connected socket, so only full loads need it. Shared by the `page`
// fixture below and by `newGuardedContext` — a hand-rolled `browser.newContext()`
// (a second, independent session — see there) gets a page the fixture never
// touches, and without this it would be exposed to the exact join-race flake
// this guard exists for.
function guardNavigation(page) {
  for (const method of ["goto", "reload"]) {
    const navigate = page[method].bind(page);
    page[method] = async (...args) => {
      const response = await navigate(...args);
      await waitForLiveConnected(page);
      return response;
    };
  }
  return page;
}

const test = base.test.extend({
  page: async ({ page }, use) => {
    await use(guardNavigation(page));
  },
});

// A second, independent browser session (its own cookies/storage) — for
// journeys that need two genuinely different signed-in users interacting with
// the same record (e.g. #948's mid-session tag attach). The caller owns the
// returned context and must `.close()` it.
async function newGuardedContext(browser) {
  const context = await browser.newContext({ baseURL: BASE_URL });
  const page = guardNavigation(await context.newPage());
  return { context, page };
}

// ── Shared journey helpers ──────────────────────────────────────────────────
// Here rather than copied into each spec: `addBlock`'s `:visible` filter and
// `newDraftPage`'s dropdown fallback were both worked out the hard way, and a
// second copy is a second thing to forget to update.

// Demo admin + editor seeded by priv/repo/seeds.exs (mix e2e.setup).
const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };
const EDITOR = { email: "editor@kiln.test", password: "kilneditor123" };

async function signInAs(page, { email, password }) {
  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', email);
  await page.fill('input[name="user[password]"]', password);
  await page.getByRole("button", { name: /sign in/i }).click();
  // Editors/admins land on the console overview by default after sign-in
  // (#157); both seeded users carry an editorial role (see priv/repo/seeds.exs).
  await base.expect(page).toHaveURL("/editor/overview");
}

async function signInAsAdmin(page) {
  await signInAs(page, ADMIN);
}

// A second, non-admin identity — used where a journey needs two genuinely
// different sessions (e.g. #948's mid-session tag attach), rather than the
// same admin account open twice.
async function signInAsEditor(page) {
  await signInAs(page, EDITOR);
}

// Start a fresh draft of `kind` ("page" by default) from the editor index (the
// `new` handler creates an "Untitled …" draft and navigates into the editor).
// Past @max_inline_new_buttons content types the per-type "New …" buttons
// collapse into the #content-new-menu <details> dropdown, so open it first.
//
// Returns the new record's id (the last URL segment), so a caller can hold it
// for cleanup before it has typed a title — the draft is findable by nothing
// else until then.
async function newDraftContent(page, kind = "page") {
  await page.goto("/editor");
  const newMenu = page.locator("#content-new-menu summary");
  if (await newMenu.count()) await newMenu.click();
  await page.click(`button[phx-click="new"][phx-value-kind="${kind}"]`);
  await page.waitForURL(new RegExp(`/editor/(content/${kind}|${kind}s)/`));
  await base.expect(page.locator('form[id$="-editor"]')).toBeVisible();
  return new URL(page.url()).pathname.split("/").pop();
}

async function newDraftPage(page) {
  return newDraftContent(page, "page");
}

// Give the open draft a title (and slug), press Save, and wait for the server
// to say so. The "Saved." flash is the only honest signal: an input still
// holds whatever was typed into it whether or not the phx-submit landed, so
// asserting on the field proves nothing, and navigating away before the save
// round-trips leaves an "Untitled" draft the caller's next step then can't
// find (see the fixture-race note on `waitForLiveConnected`).
async function saveDraft(page, { title, slug }) {
  await page.fill('input[name$="[title]"]', title);
  if (slug) await page.fill('input[name$="[slug]"]', slug);
  await save(page);
}

// Press Save on the open draft and wait for the "Saved." flash (see above).
async function save(page) {
  await page.getByRole("button", { name: /^save$/i }).click();
  await base.expect(page.locator("#flash-info")).toContainText("Saved.");
}

// A tag group scoped to specific content types, from the taxonomy page.
// `contentTypes` is required (not defaulted) rather than optional: the
// suite's database is persistent and never reset between specs (`workers:
// 1`, only `mix e2e.reset` drops it), so a group left unrestricted applies
// to every content type forever and can make another spec's "no tags yet"
// starting state unreachable — see tag_picker_midsession.spec.js. Making
// every caller name its content types is a structural nudge against
// repeating that mistake, not just a comment asking nicely.
async function createTagGroup(page, name, contentTypes) {
  if (!Array.isArray(contentTypes) || contentTypes.length === 0) {
    throw new Error("createTagGroup: contentTypes must be a non-empty array (e.g. [\"page\"])");
  }
  await page.goto("/editor/taxonomy");
  await page.fill('#new-tag_group-form input[name$="[name]"]', name);
  for (const type of contentTypes) {
    await page.check(`#new-tag_group-form input[type="checkbox"][value="${type}"]`);
  }
  await page.locator("#new-tag_group-form button[type=submit]").click();
  await base.expect(page.locator("#new-tag-form select").getByText(name)).toBeAttached();
}

// A single tag from the taxonomy page (`/editor/taxonomy`), optionally under
// an existing group. Assumes the caller is already on that page.
async function createTag(page, name, { group } = {}) {
  await page.fill('#new-tag-form input[name$="[name]"]', name);
  if (group) {
    await page.selectOption('#new-tag-form select[name$="[tag_group_id]"]', { label: group });
  }
  await page.locator("#new-tag-form button[type=submit]").click();
  // The row renders the name and the auto-derived slug, which are the same
  // string here — assert on the first match rather than fighting that.
  await base.expect(page.getByText(name, { exact: true }).first()).toBeVisible();
}

// Deletes a piece of content (admin-only, bulk-select UI) by its exact
// title, via the /editor overview's search filter + bulk-delete action.
// Best-effort: if nothing matches, this is a no-op rather than a failure —
// callers use it from cleanup, where the thing to delete may never have
// been created if an earlier step in the test already failed.
async function deleteContentByTitle(page, title) {
  await page.goto(`/editor?q=${encodeURIComponent(title)}`);
  const checkbox = page.getByRole("checkbox", { name: `Select ${title}`, exact: true });
  if ((await checkbox.count()) === 0) return;

  await checkbox.check();
  await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
  await page.locator('button[phx-click="confirm_bulk"]').click();
  await base.expect(checkbox).toHaveCount(0);
}

// Deletes a piece of content by kind + id, via the same /editor overview
// bulk-delete action as `deleteContentByTitle`, but locating the row by its
// `li#{kind}-{id}` markup instead of a title search. Use this over
// `deleteContentByTitle` when the record's title may never have been set —
// e.g. a draft created by `newDraftContent` where a failure happened before
// the caller's own title `fill()` landed, leaving it as "Untitled …" forever
// findable only by the id captured right after creation. Best-effort, same
// as `deleteContentByTitle`: a missing row is a no-op.
async function deleteContentById(page, kind, id) {
  await page.goto("/editor");
  const row = page.locator(`li[id="${kind}-${id}"]`);
  if ((await row.count()) === 0) return;

  await row.getByRole("checkbox").check();
  await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
  await page.locator('button[phx-click="confirm_bulk"]').click();
  await base.expect(row).toHaveCount(0);
}

// Deletes a single tag by name from the taxonomy page (`/editor/taxonomy`).
// Best-effort, same as `deleteContentByTitle`: a missing row is a no-op
// rather than a failure, since callers use this from cleanup where the tag
// may never have been created if an earlier step already failed.
async function deleteTagByName(page, name) {
  await page.goto("/editor/taxonomy");
  const row = page.locator("li").filter({ hasText: name }).first();
  if ((await row.count()) === 0) return;

  page.once("dialog", dialog => dialog.accept());
  await row.getByRole("button", { name: `Delete ${name}` }).click();
  await base.expect(page.getByText(name, { exact: true })).toHaveCount(0);
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
  newGuardedContext,
  ADMIN,
  EDITOR,
  signInAsAdmin,
  signInAsEditor,
  newDraftPage,
  newDraftContent,
  saveDraft,
  save,
  addBlock,
  createTagGroup,
  createTag,
  deleteContentByTitle,
  deleteContentById,
  deleteTagByName,
};
