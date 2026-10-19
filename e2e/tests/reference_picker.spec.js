// @ts-check
//
// The reference picker (R9, docs/relationships-plan.md): a `multiple`
// reference field is filled from the keyboard — type to search, arrow to an
// option, Enter to pick, Escape to close — and reordered by dragging a row's
// handle. `ReferencePickerTest` pushes the component's events itself, which
// proves what the server does with them and nothing about whether the keys
// and the drag produce them: that half lives in assets/js/reference_picker.js
// and can only fail in a browser.
//
// "Add new Page" (create and connect) renders its small form inside the
// editor form, so Enter in it must create rather than save the document, and
// Escape must close it — the hook again.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft, save } = require("./fixtures");

test.describe("reference picker", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;
  /** @type {string[]} */
  let pageIds;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_refs_${stamp}`;
    pageIds = [];
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Entries of the type, then the pages, the field and the type — the same
    // dependency order dynamic_type.spec.js cleans up in.
    await page.goto("/editor");
    const rows = page.locator(`li[id^="${name}-"], li[id^="page-"]`).filter({ hasText: stamp });
    if (await rows.count()) {
      for (const row of await rows.all()) await row.getByRole("checkbox").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(rows).toHaveCount(0);
    }

    await page.goto("/editor/fields");
    const field = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${name}_see")`) });
    if (await field.count()) {
      page.once("dialog", dialog => dialog.accept());
      await field.getByRole("button", { name: "Delete field" }).click();
      await expect(field).toHaveCount(0);
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: name });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  /** A type with a list-of-pages reference field. @param {import("@playwright/test").Page} page */
  async function createTypeWithReferences(page) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Refs ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Refs ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    // A reference is "A relationship" since #2025: picked first, then named.
    await page.locator("#new-field-kind-relationship").check();
    await page.fill('#new-field-form input[name="field_definition[label]"]', "See also");
    await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_see`);
    // "Links to" is a set of checkboxes since R2 (#2004): one ticked type is
    // saved as `target_type`.
    await page.locator("#new-field-targets-page").check();
    await page.locator("#new-field-multiple-true").check();
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${name}_see")`)).toBeVisible();
  }

  test("pick from the keyboard, reorder by dragging, and it saves", async ({ page }) => {
    for (const word of ["Alder", "Birch", "Cedar"]) {
      pageIds.push(await newDraftContent(page, "page"));
      await saveDraft(page, { title: `${word} ${stamp}`, slug: `${word.toLowerCase()}-${stamp}` });
    }

    await createTypeWithReferences(page);
    await newDraftContent(page, name);

    const field = `${name}_see`;
    const search = page.locator(`#custom-field-${field}-search`);
    const listbox = page.locator(`#custom-field-${field}-listbox`);
    const rows = page.locator(`#custom-field-${field}-items > li`);
    const titles = () => rows.locator("p.truncate").allTextContents();

    // Type to search; Down moves into the options, Enter picks — and Enter
    // never submits the editor form.
    await search.click();
    await search.pressSequentially(stamp);
    await expect(listbox.getByRole("option")).toHaveCount(3);
    await search.press("ArrowDown");
    await expect(search).toHaveAttribute("aria-activedescendant", /-opt-/);
    await search.press("Enter");
    await expect.poll(titles).toEqual([`Alder ${stamp}`]);

    // The list stays open, minus the pick; focus stays in the search.
    await expect(listbox.getByRole("option")).toHaveCount(2);
    await expect(search).toBeFocused();
    await search.press("ArrowDown");
    await search.press("ArrowDown");
    await search.press("Enter");
    await expect.poll(titles).toEqual([`Alder ${stamp}`, `Cedar ${stamp}`]);

    await search.press("Escape");
    await expect(listbox).toHaveCount(0);
    await expect(search).toHaveAttribute("aria-expanded", "false");

    // Drag Cedar by its handle above Alder.
    await rows.nth(1).locator("[data-drag-handle]").dragTo(rows.nth(0), { targetPosition: { x: 20, y: 4 } });
    await expect.poll(titles).toEqual([`Cedar ${stamp}`, `Alder ${stamp}`]);

    await saveDraft(page, { title: `Refs ${stamp}`, slug: `refs-${stamp}` });
    await page.reload();
    await expect.poll(titles).toEqual([`Cedar ${stamp}`, `Alder ${stamp}`]);

    // Removing a row moves focus to the next one's remove button.
    await rows.nth(0).locator("[data-ref-remove]").click();
    await expect.poll(titles).toEqual([`Alder ${stamp}`]);
    await expect(rows.nth(0).locator("[data-ref-remove]")).toBeFocused();
    await save(page);
  });

  test("add a new page from the picker and connect it, from the keyboard", async ({ page }) => {
    await createTypeWithReferences(page);
    await newDraftContent(page, name);
    await saveDraft(page, { title: `Refs ${stamp}`, slug: `refs-${stamp}` });

    const field = `${name}_see`;
    const addNew = page.locator(`#custom-field-${field}-new-page`);
    const form = page.locator(`#custom-field-${field}-new-form`);
    const title = page.locator(`#custom-field-${field}-new-form-title`);
    const rows = page.locator(`#custom-field-${field}-items > li`);
    const titles = () => rows.locator("p.truncate").allTextContents();

    // Escape closes the form and hands focus back to "Add new Page".
    await expect(addNew).toHaveText(/Add new Page/);
    await addNew.click();
    await expect(title).toBeFocused();
    await title.press("Escape");
    await expect(form).toHaveCount(0);
    await expect(addNew).toBeFocused();

    // Enter creates and connects — it doesn't save the document.
    await addNew.click();
    await title.pressSequentially(`Fresh ${stamp}`);
    await title.press("Enter");
    await expect.poll(titles).toEqual([`Fresh ${stamp}`]);
    await expect(rows.nth(0)).toContainText("Draft");
    await expect(rows.nth(0).locator('a[href^="/editor/content/page/"]')).toHaveCount(1);
    await expect(form).toHaveCount(0);
    await expect(page.locator(`#custom-field-${field}-search`)).toBeFocused();

    // The connection is part of the document's change, saved with it.
    await save(page);
    await page.reload();
    await expect.poll(titles).toEqual([`Fresh ${stamp}`]);
  });
});
