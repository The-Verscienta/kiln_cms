// @ts-check
//
// Custom-field columns in the content list. With one content type chosen,
// /editor offers a "Columns" disclosure; the fields ticked there show as a
// label/value strip on every row and are remembered per user, so a reload
// brings them back. Columns shares the New menu's `data-autoclose` shape
// (app.js closes either when the other, or anything outside, is clicked), and
// ticking a column must not drop a row selection.
//
// The seeds define only page and post, so the spec defines two types of its
// own (one with two string fields) to cross the New menu's threshold, and
// removes everything again afterwards.
const { test, expect, signInAsAdmin, waitForLiveConnected, newDraftContent, saveDraft } = require("./fixtures");

test.describe("content list field columns", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let nameA;
  /** @type {string} */
  let nameB;
  /** @type {string[]} */
  let fieldNames;
  /** @type {string} */
  let title;
  /** @type {string} */
  let draftId;

  /** @param {import("@playwright/test").Page} page @param {string} name */
  async function defineType(page, name) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `Cols ${name}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `Cols ${name}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page.locator("#flash-info")).toContainText("Content type created.");
  }

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    nameA = `e2e_cols_a_${stamp}`;
    nameB = `e2e_cols_b_${stamp}`;
    fieldNames = [`shade_${stamp}`, `origin_${stamp}`];
    title = `Cols Draft ${stamp}`;
    await signInAsAdmin(page);

    await defineType(page, nameA);
    await defineType(page, nameB);

    for (const [index, fieldName] of fieldNames.entries()) {
      await page.goto("/editor/fields");
      await page.locator("#new-field-form").getByRole("checkbox", { name: `Cols ${nameA}`, exact: true }).check();
      await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "string");
      await page.fill('#new-field-form input[name="field_definition[label]"]', index === 0 ? "Shade" : "Origin");
      await page.fill('#new-field-form input[name="field_definition[name]"]', fieldName);
      await page.locator("#new-field-form button[type=submit]").click();
      await expect(page.locator("#flash-info")).toContainText("Field added.");
    }

    draftId = await newDraftContent(page, nameA);
    await page.locator(`#custom-fields #custom-field-${fieldNames[0]}`).fill("Teal");
    await page.locator(`#custom-fields #custom-field-${fieldNames[1]}`).fill("Lisbon");
    await saveDraft(page, { title, slug: `e2e-cols-${stamp}` });
  });

  test.afterEach(async ({ page }) => {
    // Entries first (an archived type's entries drop out of the list), then the
    // fields, then the types, so nothing of this run stays in the persistent
    // e2e database and the seeds' inline "New" buttons come back.
    await page.goto("/editor");
    const rows = page.locator(`li[id^="${nameA}-"]`);
    if (await rows.count()) {
      for (const row of await rows.all()) await row.getByRole("checkbox").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(rows).toHaveCount(0);
    }

    await page.goto("/editor/fields");
    for (const fieldName of fieldNames) {
      const field = page
        .locator('li[id^="field-"]')
        .filter({ has: page.locator(`code:text-is("${fieldName}")`) });
      if (await field.count()) {
        page.once("dialog", dialog => dialog.accept());
        await field.getByRole("button", { name: "Delete field" }).click();
        await expect(field).toHaveCount(0);
      }
    }

    for (const name of [nameA, nameB]) {
      await page.goto("/editor/types");
      const type = page.locator("li[id^='type-']").filter({ hasText: name });
      if (await type.count()) {
        page.once("dialog", dialog => dialog.accept());
        await type.getByRole("button", { name: "Archive content type" }).click();
        await expect(type).toHaveCount(0);
      }
    }
  });

  test("chosen columns show on the row, are remembered across a reload, and keep the selection", async ({
    page,
  }) => {
    await page.goto(`/editor?type=${nameA}`);
    await waitForLiveConnected(page);

    const row = page.locator(`li[id="${nameA}-${draftId}"]`);
    const strip = row.locator("dl");
    await expect(row).toBeVisible();
    await expect(strip).toHaveCount(0);

    // Open the picker and tick Shade: the strip appears on the row.
    await page.locator("#content-columns-toggle").click();
    const panel = page.locator("#content-columns-panel");
    await expect(panel).toBeVisible();
    await panel.getByRole("checkbox", { name: "Shade" }).check();
    await expect(strip).toContainText("Shade");
    await expect(strip).toContainText("Teal");
    await expect(strip).not.toContainText("Origin");

    // A row selection survives a change of columns (a click on the row is an
    // outside click, so the panel is reopened after it), and the panel stays
    // open across the patch that redraws the list.
    await row.getByRole("checkbox").first().check();
    await expect(page.locator("#content-selected-count")).toContainText("1 selected");
    await expect(panel).toBeHidden();
    await page.locator("#content-columns-toggle").click();
    await expect(panel).toBeVisible();
    await panel.getByRole("checkbox", { name: "Origin" }).check();
    await expect(strip).toContainText("Lisbon");
    await expect(page.locator("#content-selected-count")).toContainText("1 selected");
    await expect(panel).toBeVisible();

    // Remembered: a full reload still shows both columns.
    await page.reload();
    await waitForLiveConnected(page);
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toContainText("Teal");
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toContainText("Lisbon");
    await page.locator("#content-columns-toggle").click();
    await expect(page.locator("#content-columns-panel").getByRole("checkbox", { name: "Shade" })).toBeChecked();

    // Untick both and the strip goes.
    await page.locator("#content-columns-panel").getByRole("checkbox", { name: "Shade" }).uncheck();
    await page.locator("#content-columns-panel").getByRole("checkbox", { name: "Origin" }).uncheck();
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toHaveCount(0);
  });

  test("with every type shown there is a hint, not a picker, and no strip", async ({ page }) => {
    await page.goto(`/editor?q=${encodeURIComponent(title)}`);
    await waitForLiveConnected(page);

    await expect(page.locator(`li[id="${nameA}-${draftId}"]`)).toBeVisible();
    await expect(page.locator("#content-columns")).toHaveCount(0);
    await expect(page.locator("#content-columns-hint")).toBeVisible();
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toHaveCount(0);
  });

  test("Columns and the New menu close each other, and an outside click closes Columns", async ({ page }) => {
    await page.goto(`/editor?type=${nameA}`);
    await waitForLiveConnected(page);

    const newToggle = page.locator("#content-new-menu-toggle");
    const newPanel = page.locator("#content-new-menu-list");
    const colsToggle = page.locator("#content-columns-toggle");
    const colsPanel = page.locator("#content-columns-panel");

    await newToggle.click();
    await expect(newPanel).toBeVisible();
    await expect(colsPanel).toBeHidden();

    // Opening Columns closes the New menu...
    await colsToggle.click();
    await expect(colsPanel).toBeVisible();
    await expect(colsToggle).toHaveAttribute("aria-expanded", "true");
    await expect(newPanel).toBeHidden();
    await expect(newToggle).toHaveAttribute("aria-expanded", "false");

    // ...and opening the New menu closes Columns.
    await newToggle.click();
    await expect(newPanel).toBeVisible();
    await expect(colsPanel).toBeHidden();
    await expect(colsToggle).toHaveAttribute("aria-expanded", "false");

    // A click outside closes Columns too.
    await colsToggle.click();
    await expect(colsPanel).toBeVisible();
    await page.locator("h1").first().click();
    await expect(colsPanel).toBeHidden();
  });
});
