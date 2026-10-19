// @ts-check
//
// Related content through the reference picker (#2025, R9 in
// docs/relationships-plan.md): the "Related posts" list in the inspector's
// Settings is the same picker a reference field uses, over the record's own
// type. `RelatedContentPickerTest` pushes the component's events itself; the
// keys and the drag that produce them live in assets/js/reference_picker.js,
// and the order they leave must come back after a save and a reload.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft } = require("./fixtures");

test.describe("related content picker", () => {
  /** @type {string} */
  let stamp;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    await page.goto("/editor");
    const rows = page.locator('li[id^="post-"]').filter({ hasText: stamp });
    if (await rows.count()) {
      for (const row of await rows.all()) await row.getByRole("checkbox").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(rows).toHaveCount(0);
    }
  });

  test("search, pick from the keyboard, drag to reorder, and the order saves", async ({ page }) => {
    for (const word of ["Alder", "Birch", "Cedar"]) {
      await newDraftContent(page, "post");
      await saveDraft(page, { title: `${word} ${stamp}`, slug: `${word.toLowerCase()}-${stamp}` });
    }

    await newDraftContent(page, "post");
    await saveDraft(page, { title: `Source ${stamp}`, slug: `source-${stamp}` });
    await page.click('button[role="tab"][phx-value-tab="settings"]');

    const root = "#custom-field-_related";
    const search = page.locator(`${root}-search`);
    const listbox = page.locator(`${root}-listbox`);
    const rows = page.locator(`${root}-items > li`);
    const titles = () => rows.locator("p.truncate").allTextContents();

    await expect(page.locator(root)).toContainText("Related posts");
    await expect(page.locator("#related-content-hint")).toContainText("reference field");

    // Its own type only, and never the record being edited.
    await search.click();
    await search.pressSequentially(stamp);
    await expect(listbox.getByRole("option")).toHaveCount(3);
    await expect(listbox).not.toContainText(`Source ${stamp}`);

    await search.press("ArrowDown");
    await search.press("Enter");
    await expect(listbox.getByRole("option")).toHaveCount(2);
    await search.press("ArrowDown");
    await search.press("ArrowDown");
    await search.press("Enter");
    await expect(rows).toHaveCount(2);
    const picked = await titles();
    await search.press("Escape");
    await expect(listbox).toHaveCount(0);

    // Drag the second row above the first.
    await rows.nth(1).locator("[data-drag-handle]").dragTo(rows.nth(0), { targetPosition: { x: 20, y: 4 } });
    const dragged = [picked[1], picked[0]];
    await expect.poll(titles).toEqual(dragged);

    await saveDraft(page, { title: `Source ${stamp}`, slug: `source-${stamp}` });
    await page.reload();
    await page.click('button[role="tab"][phx-value-tab="settings"]');
    await expect.poll(titles).toEqual(dragged);

    // The keyboard path: move the second row up.
    await rows.nth(1).locator("button[phx-value-dir=up]").click();
    await expect.poll(titles).toEqual(picked);
  });
});
