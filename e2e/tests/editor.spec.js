// @ts-check
const { test, expect } = require("@playwright/test");

// Demo admin seeded by priv/repo/seeds.exs (mix e2e.setup).
const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

async function signInAsAdmin(page) {
  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();
  // Successful sign-in redirects to the site root.
  await expect(page).toHaveURL("/");
}

// Start a fresh draft page from the editor index and return its slug (the
// `new` handler creates an "Untitled …" draft and navigates into the editor).
async function newDraftPage(page) {
  await page.goto("/editor");
  await page.click('button[phx-click="new"][phx-value-kind="page"]');
  await page.waitForURL(/\/editor\/(content\/page|pages)\//);
  await expect(page.locator('form[id$="-editor"]')).toBeVisible();
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
    await page.click('button[phx-click="add_block"][phx-value-type="rich_text"]');
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

    await page.click('button[phx-click="add_block"][phx-value-type="rich_text"]');
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

    // Two heading blocks (simple textareas) so order is easy to assert.
    await page.click('button[phx-click="add_block"][phx-value-type="heading"]');
    await page.click('button[phx-click="add_block"][phx-value-type="heading"]');

    const areas = page.locator('#blocks-sortable textarea[name$="[content]"]');
    await expect(areas).toHaveCount(2);
    await areas.nth(0).fill("First");
    await areas.nth(1).fill("Second");
    await page.waitForTimeout(400);

    // Preview (right pane) renders heading blocks as <h2>, in block order.
    const previewHeadings = page.locator("article h2");
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
