// @ts-check
//
// Conditional custom fields (#2277) in a real browser. The ExUnit tests prove
// what the server seeds (`data-cf-*`, the starting hidden state) and what a
// save accepts; only a browser can show that `FieldConditions` (assets/js)
// hides and shows a field as its select changes, that the browser's own
// `required` blocks a save while the rule holds, that a hidden field's stored
// value still posts, and that the LiveView patch each keystroke brings does
// not undo any of it.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft, holdsAcross } = require("./fixtures");

test.describe("conditional custom fields", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_cond_${stamp}`;
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

    // The fields that read the select go first: a field other rules read can't be deleted.
    await page.goto("/editor/fields");
    for (const suffix of ["note", "extra", "kind"]) {
      const field = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${name}_${suffix}")`) });
      if (await field.count()) {
        page.once("dialog", dialog => dialog.accept());
        await field.getByRole("button", { name: "Delete field", exact: true }).click();
        await expect(field).toHaveCount(0);
      }
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: name });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  /**
   * A type with a select (`kind`: a / other), a text field that is required
   * when kind is "other" (`note`), and one shown only when it is (`extra`).
   * The rules are authored through the Conditions disclosure.
   * @param {import("@playwright/test").Page} page
   */
  async function createType(page) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Cond ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Cond ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    await page.fill('#new-field-form input[name="field_definition[label]"]', "Kind");
    await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_kind`);
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "select");
    await page.fill('#new-field-form textarea[name="field_definition[options]"]', "a\nother");
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${name}_kind")`)).toBeVisible();

    for (const [label, suffix, rule] of [
      ["Note", "note", "required_when"],
      ["Extra", "extra", "visible_when"],
    ]) {
      await page.fill('#new-field-form input[name="field_definition[label]"]', label);
      await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_${suffix}`);
      // The disclosure keeps its state across the form's reset: open it only if it is shut.
      const disclosure = page.locator("#new-field-conditions");
      if (!(await disclosure.evaluate(el => /** @type {HTMLDetailsElement} */ (el).open))) {
        await disclosure.locator("> summary").click();
      }
      await page.locator(`#new-field-conditions-${rule}-add`).click();
      await page.selectOption(`#new-field-conditions-${rule}-row-0-field`, `${name}_kind`);
      await page.selectOption(`#new-field-conditions-${rule}-row-0-value`, "other");
      await page.locator("#new-field-form button[type=submit]").click();
      await expect(page.locator(`code:text-is("${name}_${suffix}")`)).toBeVisible();
    }
  }

  test("the select shows and hides fields, and required follows the rule", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const kind = page.locator(`#custom-field-${name}_kind`);
    const note = page.locator(`#custom-field-${name}_note`);
    const extra = page.locator(`#custom-field-${name}_extra`);
    const extraBox = page.locator(`#cf-cond-${name}_extra`);

    // Nothing chosen: the rule is false, so Extra is hidden and Note is optional.
    await expect(extraBox).toBeHidden();
    await expect(extraBox).toHaveAttribute("aria-hidden", "true");
    await expect(note).toBeVisible();
    await expect(note).not.toHaveJSProperty("required", true);

    await kind.selectOption("other");
    await expect(extraBox).toBeVisible();
    await expect(extraBox).not.toHaveAttribute("aria-hidden", "true");
    await expect(note).toHaveJSProperty("required", true);

    // The browser's own validation stops a save while the rule holds.
    await page.fill('input[name$="[title]"]', `Cond ${stamp}`);
    expect(await note.evaluate(el => /** @type {HTMLInputElement} */ (el).validity.valueMissing)).toBe(true);
    expect(await note.evaluate(el => /** @type {HTMLInputElement} */ (el).form.checkValidity())).toBe(false);

    await note.fill("because");
    await extra.fill("kept while hidden");

    // Back to "a": Extra goes, Note stops being required, the hidden value is still in the form.
    await kind.selectOption("a");
    await expect(extraBox).toBeHidden();
    await expect(note).not.toHaveJSProperty("required", true);
    await expect(extra).toHaveValue("kept while hidden");
    expect(await note.evaluate(el => /** @type {HTMLInputElement} */ (el).form.checkValidity())).toBe(true);

    // A hidden field's value still saves, and shows again with its rule.
    await saveDraft(page, { title: `Cond ${stamp}`, slug: `cond-${stamp}` });
    await page.reload();
    await expect(extraBox).toBeHidden();
    await expect(note).not.toHaveJSProperty("required", true);
    await kind.selectOption("other");
    await expect(extraBox).toBeVisible();
    await expect(extra).toHaveValue("kept while hidden");
  });

  test("a LiveView patch does not undo what the hook set", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const kind = page.locator(`#custom-field-${name}_kind`);
    const note = page.locator(`#custom-field-${name}_note`);
    const extraBox = page.locator(`#cf-cond-${name}_extra`);
    const state = async () => ({
      extraHidden: await extraBox.evaluate(el => el.classList.contains("hidden")),
      noteRequired: await note.evaluate(el => /** @type {HTMLInputElement} */ (el).required),
    });

    await kind.selectOption("other");
    await expect(extraBox).toBeVisible();
    await expect(note).toHaveJSProperty("required", true);

    // Typing anywhere in the form is a phx-change round trip that re-renders the panel.
    await page.locator('input[name$="[title]"]').pressSequentially("typing triggers patches");
    await note.pressSequentially("and so does this");
    await holdsAcross(page, state, { extraHidden: false, noteRequired: true });

    await kind.selectOption("a");
    await expect(extraBox).toBeHidden();
    await page.locator('input[name$="[title]"]').pressSequentially(" more");
    await note.pressSequentially(" more");
    await holdsAcross(page, state, { extraHidden: true, noteRequired: false });
  });
});
