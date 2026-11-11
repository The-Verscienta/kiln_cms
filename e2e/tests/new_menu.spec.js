// @ts-check
//
// The content list's collapsed "New" menu (#2145). Past three content types,
// /editor folds its "New …" buttons into a disclosure: a <button
// aria-expanded aria-controls> that shows and hides the panel. app.js's shared
// `data-autoclose` handler closes it on Escape or a click outside, and claims
// Escape only while the menu is open. A LiveView test can't run app.js, so the
// keyboard and focus contract is pinned here.
//
// The demo seeds define only page and post, so the spec defines two types of
// its own to cross the threshold, and archives them again afterwards.
const { test, expect, signInAsAdmin, waitForLiveConnected, newDraftContent, saveDraft } = require("./fixtures");

test.describe("content list New menu", () => {
  /** @type {string[]} */
  let names;

  test.beforeEach(async ({ page }) => {
    const stamp = String(Date.now());
    names = [`e2e_menu_a_${stamp}`, `e2e_menu_b_${stamp}`];
    await signInAsAdmin(page);

    for (const name of names) {
      await page.goto("/editor/types");
      await page.fill('#new-type-form input[name="type_definition[label]"]', `Menu ${name}`);
      await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `Menu ${name}s`);
      await page.fill('#new-type-form input[name="type_definition[name]"]', name);
      await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
      await expect(page.locator("#flash-info")).toContainText("Content type created.");
    }
  });

  test.afterEach(async ({ page }) => {
    // Archive both types so later specs see the seeds' inline buttons again.
    for (const name of names) {
      await page.goto("/editor/types");
      const type = page.locator("li[id^='type-']").filter({ hasText: name });
      if (await type.count()) {
        page.once("dialog", dialog => dialog.accept());
        await type.getByRole("button", { name: "Archive content type" }).click();
        await expect(type).toHaveCount(0);
      }
    }
  });

  test("is a button that opens, closes on Escape and outside clicks, and leaves other Escapes alone", async ({
    page,
  }) => {
    await page.goto("/editor");
    await waitForLiveConnected(page);

    const toggle = page.locator("#content-new-menu-toggle");
    const panel = page.locator("#content-new-menu-list");

    // A native button, collapsed, naming the panel it controls.
    await expect(page.getByRole("button", { name: "New", exact: true })).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(toggle).toHaveAttribute("aria-controls", "content-new-menu-list");
    await expect(panel).toBeHidden();

    // Escape while the menu is closed belongs to whatever has focus: the
    // search box keeps it.
    const search = page.locator("#content-search-input");
    await search.focus();
    await page.keyboard.press("Escape");
    await expect(search).toBeFocused();
    await expect(toggle).not.toBeFocused();

    // Keyboard open: Enter on the focused trigger shows the panel.
    await toggle.focus();
    await page.keyboard.press("Enter");
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toBeVisible();
    await expect(panel.locator(`button[phx-value-kind="${names[0]}"]`)).toBeVisible();

    // Tab into the panel, then Escape closes it and hands focus back.
    await page.keyboard.press("Tab");
    await expect(panel.locator("button").first()).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(toggle).toBeFocused();

    // A click outside closes it too.
    await toggle.click();
    await expect(panel).toBeVisible();
    await page.locator("h1").first().click();
    await expect(panel).toBeHidden();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");

    // And an item still opens a new draft of its type.
    await toggle.click();
    await panel.locator(`button[phx-value-kind="${names[0]}"]`).click();
    await page.waitForURL(new RegExp(`/editor/content/${names[0]}/new$`));
  });
  // New menu, Columns and Export (#2293) are three disclosures with one
  // `data-autoclose` shape: opening one closes the others, and a row
  // selection (an outside click) closes whichever is open without dropping
  // the bulk bar, whose "Export selected" link carries the selected id.
  test("New menu, Columns and Export close each other, and the bulk bar still works", async ({ page }) => {
    const stamp = String(Date.now());
    const fieldName = `menu_field_${stamp}`;
    const title = `Menu Draft ${stamp}`;

    await page.goto("/editor/fields");
    await page.locator("#new-field-form").getByRole("checkbox", { name: `Menu ${names[0]}`, exact: true }).check();
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "string");
    await page.fill('#new-field-form input[name="field_definition[label]"]', "Shade");
    await page.fill('#new-field-form input[name="field_definition[name]"]', fieldName);
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator("#flash-info")).toContainText("Field added.");

    try {
      const draftId = await newDraftContent(page, names[0]);
      await saveDraft(page, { title, slug: `e2e-menu-${stamp}` });

      await page.goto(`/editor?type=${names[0]}`);
      await waitForLiveConnected(page);

      const toggles = {
        new: page.locator("#content-new-menu-toggle"),
        cols: page.locator("#content-columns-toggle"),
        exp: page.locator("#content-export-toggle"),
      };
      const panels = {
        new: page.locator("#content-new-menu-list"),
        cols: page.locator("#content-columns-panel"),
        exp: page.locator("#content-export-panel"),
      };
      const keys = /** @type {const} */ (["new", "cols", "exp"]);

      /** Exactly `open` is expanded and visible; the other two are collapsed.
       * @param {"new" | "cols" | "exp" | "none"} open */
      async function onlyOpen(open) {
        for (const key of keys) {
          if (key === open) {
            await expect(panels[key]).toBeVisible();
            await expect(toggles[key]).toHaveAttribute("aria-expanded", "true");
          } else {
            await expect(panels[key]).toBeHidden();
            await expect(toggles[key]).toHaveAttribute("aria-expanded", "false");
          }
        }
      }

      // Each one, opened from a state where another is open, closes that one.
      await toggles.new.click();
      await onlyOpen("new");
      await toggles.exp.click();
      await onlyOpen("exp");
      await expect(page.locator("#export-summary")).toContainText("Export 1 matching");
      await toggles.cols.click();
      await onlyOpen("cols");
      await toggles.exp.click();
      await onlyOpen("exp");
      await toggles.new.click();
      await onlyOpen("new");

      // The export links are real downloads of the current list.
      await toggles.exp.click();
      await expect(page.locator("#export-csv")).toHaveAttribute("href", /\/editor\/content\/export\.csv\?/);
      await expect(page.locator("#export-json")).toHaveAttribute("href", /\/editor\/content\/export\.json\?/);

      // A row selection is an outside click: it closes Export, and the bulk
      // bar offers its own export of just that row.
      const row = page.locator(`li[id="${names[0]}-${draftId}"]`);
      await row.getByRole("checkbox").first().check();
      await expect(page.locator("#content-selected-count")).toContainText("1 selected");
      await onlyOpen("none");
      await expect(page.locator("#bulk-export-selected")).toHaveAttribute("href", new RegExp(`ids=${draftId}`));
      await expect(page.locator('#bulk-actions button[phx-value-action="delete"]')).toBeVisible();

      // With a selection the disclosures still open and still exclude each other.
      await toggles.exp.click();
      await onlyOpen("exp");
      await toggles.cols.click();
      await onlyOpen("cols");
      await expect(page.locator("#content-selected-count")).toContainText("1 selected");
    } finally {
      await page.goto(`/editor?type=${names[0]}`);
      await waitForLiveConnected(page);
      const rows = page.locator(`li[id^="${names[0]}-"]`);
      if (await rows.count()) {
        await page.getByLabel("Select all").check();
        await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
        await page.locator('button[phx-click="confirm_bulk"]').click();
        await expect(rows).toHaveCount(0);
      }

      await page.goto("/editor/fields");
      const field = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${fieldName}")`) });
      if (await field.count()) {
        page.once("dialog", dialog => dialog.accept());
        await field.getByRole("button", { name: "Delete field" }).click();
        await expect(field).toHaveCount(0);
      }
    }
  });
});
