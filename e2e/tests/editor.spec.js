// @ts-check
// `test` here carries the LiveView navigation guard (see fixtures.js): every
// page.goto/reload waits for the LiveView to finish joining its channel, so a
// phx-click or phx-submit issued right after a page load can't be swallowed.
const { test, expect } = require("./fixtures");

// Demo admin seeded by priv/repo/seeds.exs (mix e2e.setup).
const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

async function signInAsAdmin(page) {
  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();
  // Editors/admins land on the console overview by default after sign-in
  // (#157); this seeded user has the :admin role (see priv/repo/seeds.exs).
  await expect(page).toHaveURL("/editor/overview");
}

// Start a fresh draft page from the editor index and return its slug (the
// `new` handler creates an "Untitled …" draft and navigates into the editor).
// Past @max_inline_new_buttons content types the per-type "New …" buttons
// collapse into the #content-new-menu <details> dropdown, so open it first.
async function newDraftPage(page) {
  await page.goto("/editor");
  const newMenu = page.locator("#content-new-menu summary");
  if (await newMenu.count()) await newMenu.click();
  await page.click('button[phx-click="new"][phx-value-kind="page"]');
  await page.waitForURL(/\/editor\/(content\/page|pages)\//);
  await expect(page.locator('form[id$="-editor"]')).toBeVisible();
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

  // #823. A rich-text link only exists if it survives being *parsed back* into
  // TipTap: the stored Portable Text is rendered to HTML to seed the editor, and
  // an extension list without a Link mark drops the anchor there and then
  // autosaves prose that no longer has it. That is invisible to the Elixir
  // round-trip tests — `to_html/1` and `from_tiptap/1` were both correct
  // throughout the bug — so the regression has to be caught in a real browser.
  test("a link authored in a rich-text block survives the editor round-trip", async ({ page }) => {
    const slug = `e2e-link-${Date.now()}`;
    const linkText = "the refund policy";
    await newDraftPage(page);
    await page.fill('input[name$="[title]"]', "E2E Link");
    await page.fill('input[name$="[slug]"]', slug);

    await addBlock(page, "rich_text");
    const editor = page.locator('[phx-hook="RichText"] [data-editor] .ProseMirror').first();
    await expect(editor).toBeVisible();
    await editor.click();
    await page.keyboard.type(linkText);

    // Select the prose, then link it. `Mod-a` is ProseMirror's own selectAll
    // keybinding, so it lands as an editor command rather than depending on the
    // browser's native caret movement — which arrow keys in an automated
    // contenteditable can't be relied on for.
    await page.keyboard.press("ControlOrMeta+a");
    // ⌘K / Ctrl-K is bound on the editor itself and pre-empts the global
    // search palette (which skips contenteditable targets anyway).
    await page.keyboard.press("ControlOrMeta+k");
    const url = page.locator(".rt-link-prompt input");
    await expect(url).toBeFocused();

    // A scheme the server would blank is refused here, with a reason, and the
    // document is left alone — the popover stays open to be corrected.
    await url.fill("javascript:alert(1)");
    await page.keyboard.press("Enter");
    await expect(page.locator(".rt-link-error")).toBeVisible();
    await expect(editor.locator("a")).toHaveCount(0);

    await url.fill("/refunds");
    await page.keyboard.press("Enter");
    await expect(page.locator(".rt-link-prompt")).toBeHidden();
    await expect(editor.locator('a[href="/refunds"]')).toHaveText(linkText);

    // Let the 300ms rich_text_body push flush, then save.
    await page.waitForTimeout(700);
    await page.getByRole("button", { name: /^save$/i }).click();

    // The regression: reloading re-seeds the editor from the *stored* Portable
    // Text, so the anchor here proves markDefs survived both directions.
    await page.reload();
    const reloaded = page.locator('[phx-hook="RichText"] [data-editor] .ProseMirror').first();
    await expect(reloaded.locator('a[href="/refunds"]')).toHaveText(linkText);

    // And it reaches readers: publish, then check the delivered page.
    await page.click('button[phx-click="workflow"][phx-value-action="publish"]');
    await expect(
      page.locator('button[phx-click="workflow"][phx-value-action="unpublish"]'),
    ).toBeVisible();
    await page.goto(`/${slug}`);
    await expect(page.locator('article a[href="/refunds"]')).toHaveText(linkText);
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

  test("reordering a block doesn't remount its rich-text editor", async ({ page }) => {
    // The editor host is keyed by the block's stable id, so moving the block
    // relocates the SAME ProseMirror node instead of tearing it down and
    // remounting it. Keeping the live editor instance is what preserves the
    // cursor position and undo stack across a reorder; the content (pushed via
    // the id-keyed rich_text_body event) still saves against the reordered block.
    await newDraftPage(page);
    await page.fill('input[name$="[title]"]', "E2E Reorder Editor");
    await page.fill('input[name$="[slug]"]', `e2e-reorder-editor-${Date.now()}`);

    // A heading (with identifiable text) first, then a rich-text block below it.
    await addBlock(page, "heading");
    await page.locator('#blocks-sortable textarea[name$="[text]"]').first().fill("HEADING");
    await addBlock(page, "rich_text");

    const editor = page.locator('[phx-hook="RichText"] [data-editor] .ProseMirror').first();
    await expect(editor).toBeVisible();
    await editor.click();
    await page.keyboard.type("keep-dropme");
    await expect(editor).toHaveText("keep-dropme");
    // Let the 300ms rich_text_body push flush so the server holds the document.
    await page.waitForTimeout(500);

    // Tag the live editor node with a marker no re-render would reproduce; a
    // remount would tear this node down and replace it, dropping the tag. The
    // marker surviving the reorder is exactly what preserves the editor's live
    // state (cursor + undo history) — those ride on this same instance.
    await editor.evaluate((el) => (el.dataset.survived = "yes"));

    // Move the rich-text block up above the heading (its card holds the host).
    const richCard = page
      .locator("#blocks-sortable > div")
      .filter({ has: page.locator('[phx-hook="RichText"]') });
    await richCard.locator('button[phx-value-dir="up"]').click();

    // Same DOM node survived the reorder (editor not remounted) …
    await expect(editor).toHaveAttribute("data-survived", "yes");
    // … and its content is preserved live, now in the first card.
    await expect(editor).toHaveText("keep-dropme");
    const firstCard = page.locator("#blocks-sortable > div").first();
    await expect(firstCard.locator('[phx-hook="RichText"]')).toHaveCount(1);

    // Save-time correctness (the reordered content persists against the right
    // block, matched by id) is covered exhaustively by the LiveView tests in
    // test/kiln_cms_web/live/editor_live_test.exs — this journey's job is to prove
    // in a real browser that the reorder does not remount the editor.
  });

  test("the inspector Settings tab and its fields survive per-keystroke validate patches", async ({ page }) => {
    await newDraftPage(page);

    // Theme A retired the buried SEO/Organization <details> accordions in favour
    // of a tabbed inspector rail: the SEO & scheduling and Organization sections
    // are now always-expanded <section>s inside the "Settings" panel, and which
    // panel is visible is *server* view state (@inspector_tab), toggled by CSS.
    // The regression this guards is the tabbed equivalent of the old "typing
    // must not collapse the section" bug: switching to Settings and typing in a
    // field must not bounce the rail back to its default (Preview) panel or drop
    // the field — the per-keystroke validate patch has to preserve the tab.
    const settingsTab = page.getByRole("tab", { name: /settings/i });
    const seoTitle = page.locator('input[name$="[seo_title]"]');
    const category = page.locator('select[name$="[category_id]"]');

    // Default tab is Preview, so both the Organization (category) and SEO fields
    // start hidden behind the CSS-toggled Settings panel.
    await expect(seoTitle).toBeHidden();
    await expect(category).toBeHidden();

    await settingsTab.click();
    await expect(settingsTab).toHaveAttribute("aria-selected", "true");
    // Both sections live in the one Settings panel, so both reveal together.
    await expect(category).toBeVisible();
    await expect(seoTitle).toBeVisible();

    await seoTitle.click();
    await seoTitle.pressSequentially("E2E SEO title", { delay: 30 });
    // Let the 300ms validate debounce fire and the patch come back.
    await page.waitForTimeout(700);

    // The validate patch must keep us on Settings with the fields still shown
    // and the typed value intact.
    await expect(settingsTab).toHaveAttribute("aria-selected", "true");
    await expect(seoTitle).toBeVisible();
    await expect(category).toBeVisible();
    await expect(seoTitle).toHaveValue("E2E SEO title");

    // A second edit keeps the tab put too (mirror of the old both-directions
    // assertion — the panel never flips back to Preview mid-typing).
    await seoTitle.pressSequentially(" more", { delay: 30 });
    await page.waitForTimeout(700);
    await expect(settingsTab).toHaveAttribute("aria-selected", "true");
    await expect(seoTitle).toHaveValue("E2E SEO title more");
  });
});
