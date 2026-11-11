// @ts-check
//
// A typed scalar list (#2289): a `:date` field with `multiple`. The add box is
// a date picker in the `TermPicker` hook's "none" mode — Enter or its Add
// button adds the picked date, and choosing one adds nothing by itself — and
// the items drag to reorder through the shared `Sortable` hook.
// `ScalarListFieldEditorTest` pushes `list_item_add` itself, which proves what
// the server does with the event and nothing about whether the hook sends it.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft, holdsAcross } = require("./fixtures");

test.describe("scalar list fields", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_lists_${stamp}`;
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    await page.goto("/editor");
    const rows = page.locator(`li[id^="${name}-"]`).filter({ hasText: stamp });
    if (await rows.count()) {
      for (const row of await rows.all()) await row.getByRole("checkbox").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(rows).toHaveCount(0);
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: name });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  /** @param {import("@playwright/test").Page} page */
  async function createType(page) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Lists ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Lists ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    await page.fill('#new-field-form input[name="field_definition[label]"]', "Event dates");
    await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_dates`);
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "date");
    await page.locator("#new-field-multiple-true").check();
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${name}_dates")`)).toBeVisible();
  }

  test("dates are added by Enter or the Add button, dragged, saved and reloaded", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const dates = `${name}_dates`;
    const entry = page.locator(`#custom-field-${dates}-entry`);
    const addButton = page.locator(`#custom-field-${dates}-add`);
    const rows = page.locator(`#custom-field-${dates}-items > li`);
    const items = () =>
      page
        .locator(`#custom-field-${dates}-items input[type=date]`)
        .evaluateAll(els => els.map(el => /** @type {HTMLInputElement} */ (el).value));

    await expect(entry).toHaveAttribute("type", "date");
    await expect(entry).toHaveAttribute("data-split", "none");

    // Choosing a date adds nothing until it is confirmed.
    await entry.fill("2026-05-01");
    await holdsAcross(page, () => rows.count(), 0);

    await addButton.click();
    await expect.poll(items).toEqual(["2026-05-01"]);
    await expect(entry).toHaveValue("");

    await entry.fill("2026-03-01");
    await entry.press("Enter");
    await expect.poll(items).toEqual(["2026-05-01", "2026-03-01"]);

    // A repeat adds nothing.
    await entry.fill("2026-03-01");
    await addButton.click();
    await expect(entry).toHaveValue("");
    await expect.poll(items).toEqual(["2026-05-01", "2026-03-01"]);

    // Drag March above May.
    await rows.nth(1).locator("[data-drag-handle]").dragTo(rows.nth(0), { targetPosition: { x: 4, y: 4 } });
    await expect.poll(items).toEqual(["2026-03-01", "2026-05-01"]);

    await saveDraft(page, { title: `Lists ${stamp}`, slug: `lists-${stamp}` });
    await page.reload();

    await expect.poll(items).toEqual(["2026-03-01", "2026-05-01"]);
  });
});
