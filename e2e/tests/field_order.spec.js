// @ts-check
//
// Ordering a content type's custom fields (#1818). The order on /editor/fields
// is the order the editor shows the fields in, set by dragging a field by its
// handle (the shared `Sortable` hook) or with the arrow buttons.
//
// `FieldDefinitionLiveTest` pushes the hook's "reorder" event itself, which
// proves what the server does with an order and nothing about whether a drag
// produces one — the half that can fail silently (see the calendar's
// drag-to-reschedule, which never worked until an e2e drove it).
const { test, expect, signInAsAdmin } = require("./fixtures");

test.describe("custom field order", () => {
  /** @type {string} */
  let label;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    const stamp = String(Date.now());
    label = `E2E Order ${stamp}`;
    name = `e2e_order_${stamp}`;
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Archiving the type is enough: it takes the type (and its fields) out of
    // every later spec's screens. Its fields go first so none is left behind
    // on /editor/fields under "Archived type".
    await page.goto("/editor/fields");
    const fields = page.locator(`li[id^="field-"]`).filter({ has: page.locator(`code:text-matches("^${name}_")`) });
    for (let n = await fields.count(); n > 0; n--) {
      page.once("dialog", dialog => dialog.accept());
      await fields.first().getByRole("button", { name: "Delete field" }).click();
      await expect(fields).toHaveCount(n - 1);
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: name });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  test("dragging a field by its handle reorders it, and it sticks", async ({ page }) => {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', label);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `${label}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    // Three fields; the new type stays ticked after each one.
    for (const field of ["first", "second", "third"]) {
      await page.fill('#new-field-form input[name="field_definition[label]"]', field);
      await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_${field}`);
      await page.locator("#new-field-form button[type=submit]").click();
      await expect(page.locator(`code:text-is("${name}_${field}")`)).toBeVisible();
    }

    const list = page.locator('ul[phx-hook="Sortable"]').filter({ has: page.locator(`code:text-is("${name}_first")`) });
    const order = () => list.locator("> li code").allTextContents();
    await expect.poll(order).toEqual([`${name}_first`, `${name}_second`, `${name}_third`]);

    // Drag "third" by its handle onto the top of "first".
    const row = (/** @type {string} */ field) =>
      list.locator("> li").filter({ has: page.locator(`code:text-is("${name}_${field}")`) });
    await row("third")
      .locator("[data-drag-handle]")
      .dragTo(row("first"), { targetPosition: { x: 20, y: 4 } });

    await expect.poll(order).toEqual([`${name}_third`, `${name}_first`, `${name}_second`]);

    // Saved, not just moved in the page.
    await page.reload();
    await expect.poll(order).toEqual([`${name}_third`, `${name}_first`, `${name}_second`]);

    // The arrows do the same from a keyboard.
    await row("second").getByRole("button", { name: "Move second up" }).focus();
    await page.keyboard.press("Enter");
    await expect.poll(order).toEqual([`${name}_third`, `${name}_second`, `${name}_first`]);
  });
});
