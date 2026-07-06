// @ts-check
const { test, expect } = require("@playwright/test");

// Demo admin seeded by priv/repo/seeds.exs (mix e2e.setup).
const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

// Wait until the LiveView socket has actually connected before driving any
// phx-click / phx-submit control on a freshly loaded page.
//
// Once app.js loads, LiveView binds the page's forms/buttons and *suppresses*
// their native fallback (e.g. the sign-in form's plain POST). If a click lands
// in the window after JS has bound but before the channel has joined, the event
// is swallowed and never reaches the server — the page just sits there. Locally
// the socket connects in milliseconds so this is invisible, but on a cold CI
// runner the join lags the first interaction and the click is lost, which
// surfaced as sign-in hanging on /sign-in (and "new draft" hanging on /editor).
// Gating on `isConnected()` makes the connected path deterministic.
async function waitForLiveConnected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected());
}

async function signInAsAdmin(page) {
  await page.goto("/sign-in");
  await waitForLiveConnected(page);
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();
  // Editors/admins land on the console overview by default after sign-in
  // (#157); this seeded user has the :admin role (see priv/repo/seeds.exs).
  await expect(page).toHaveURL("/editor/overview");
}

// Start a fresh draft page from the editor index and return its slug (the
// `new` handler creates an "Untitled …" draft and navigates into the editor).
async function newDraftPage(page) {
  await page.goto("/editor");
  await waitForLiveConnected(page);
  await page.click('button[phx-click="new"][phx-value-kind="page"]');
  await page.waitForURL(/\/editor\/(content\/page|pages)\//);
  await expect(page.locator('form[id$="-editor"]')).toBeVisible();
}

// The block inserter (#29) is a closed dropdown: its options only become
// visible/clickable after the "Add block" trigger opens the menu (the
// BlockInserter JS hook toggles `data-inserter-menu`'s `hidden` attribute).
// Selecting an option closes the menu again, so each insert needs its own
// trigger click.
async function addBlock(page, type) {
  await page.click("button[data-inserter-trigger]");
  await page.click(`button[phx-click="add_block"][phx-value-type="${type}"]`);
}

test.describe("editor journey", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("create → edit a rich-text block → publish → view live", async ({ page }) => {
    const slug = `e2e-page-${Date.now()}`;
    const title = "E2E Published Page";
    const body = "Hello from the Playwright editor journey";

    await newDraftPage(page);

    // Title + slug (overwrite the auto-generated placeholders).
    await page.fill('input[name$="[title]"]', title);
    await page.fill('input[name$="[slug]"]', slug);

    // Add a TipTap rich-text block and type into the ProseMirror editor.
    await addBlock(page, "rich_text");
    const editor = page.locator('[phx-hook="RichText"] [data-editor]').first();
    await expect(editor).toBeVisible();
    await editor.click();
    await page.keyboard.type(body);
    // Let the TipTap → hidden-input sync (300ms debounce) flush before saving.
    await page.waitForTimeout(700);

    // Explicit save, then publish (admin).
    await page.getByRole("button", { name: /^save$/i }).click();
    await page.click('button[phx-click="workflow"][phx-value-action="publish"]');
    // Once published the workflow control flips to "Unpublish".
    await expect(
      page.locator('button[phx-click="workflow"][phx-value-action="unpublish"]'),
    ).toBeVisible();

    // The published page is live on the public site at the root slug.
    await page.goto(`/${slug}`);
    await expect(page.locator("article h1")).toContainText(title);
    await expect(page.locator("article")).toContainText(body);
  });

  test("slash command transforms a rich-text block", async ({ page }) => {
    await newDraftPage(page);
    await page.fill('input[name$="[title]"]', "E2E Slash");
    await page.fill('input[name$="[slug]"]', `e2e-slash-${Date.now()}`);

    await addBlock(page, "rich_text");
    const editor = page.locator('[phx-hook="RichText"] [data-editor] .ProseMirror').first();
    await expect(editor).toBeVisible();
    await editor.click();

    // "/" opens the slash menu; the query filters it down to "Quote".
    await page.keyboard.type("/quote");
    const menu = page.locator(".rt-slash-menu");
    await expect(menu).toBeVisible();
    await expect(menu.getByText("Quote", { exact: true })).toBeVisible();

    // Enter applies the highlighted command: the "/quote" text is removed and
    // the block becomes a blockquote that swallows what we type next.
    await page.keyboard.press("Enter");
    await page.keyboard.type("Pearl of wisdom");
    await expect(editor.locator("blockquote")).toContainText("Pearl of wisdom");
  });

  test("reorder blocks via drag-and-drop (SortableJS)", async ({ page }) => {
    await newDraftPage(page);
    await page.fill('input[name$="[title]"]', "E2E Reorder");
    await page.fill('input[name$="[slug]"]', `e2e-reorder-${Date.now()}`);

    // Two heading blocks (simple textareas) so order is easy to assert. The
    // typed-block DSL's generic editor (dsl_block_fields) binds the primary
    // textarea to the block's first string field — for Heading that's `text`
    // (see KilnCMS.Blocks.Heading), not a generic `content`.
    await addBlock(page, "heading");
    await addBlock(page, "heading");

    const areas = page.locator('#blocks-sortable textarea[name$="[text]"]');
    await expect(areas).toHaveCount(2);
    await areas.nth(0).fill("First");
    await areas.nth(1).fill("Second");
    await page.waitForTimeout(400);

    // Preview (right pane) renders heading blocks as <h2>, in block order.
    // preview_article/1 renders the title as its own `<h2 class="text-2xl
    // font-bold">` (#174 — a single logical h1 per page) ahead of the blocks,
    // and is shared verbatim by the desktop sticky column and the mobile
    // disclosure (#138) — both stay in the DOM regardless of viewport, just
    // toggled via CSS. `:visible` picks the rendered pane for this viewport;
    // `:not(.text-2xl)` excludes the title so only block headings remain.
    const previewHeadings = page.locator("article:visible h2:not(.text-2xl)");
    await expect(previewHeadings).toHaveText(["First", "Second"]);

    // Drag the second block's handle above the first. SortableJS listens to
    // native mouse events, so drive the pointer manually with intermediate
    // steps rather than a single dragTo.
    const handles = page.locator("#blocks-sortable [data-drag-handle]");
    const src = await handles.nth(1).boundingBox();
    const dst = await handles.nth(0).boundingBox();
    if (!src || !dst) throw new Error("drag handles not found");

    await page.mouse.move(src.x + src.width / 2, src.y + src.height / 2);
    await page.mouse.down();
    // Move in steps, ending above the first handle, to trigger Sortable.
    await page.mouse.move(dst.x + dst.width / 2, dst.y - 12, { steps: 12 });
    await page.mouse.move(dst.x + dst.width / 2, dst.y - 4, { steps: 6 });
    await page.mouse.up();

    // The reorder event re-renders the form-backed preview in the new order.
    await expect(previewHeadings).toHaveText(["Second", "First"]);
  });
});
