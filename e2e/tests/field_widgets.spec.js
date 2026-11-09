// @ts-check
//
// Field widgets (#2284) in a real browser. The ExUnit tests prove the markup
// each widget renders and what a save accepts; only a browser shows that
// `FieldConditions` (assets/js) requires a radio group the way a browser
// requires one — `required` on one radio, `aria-required` on the group —
// while its `required_when` rule holds, and that ticked checkboxes post and
// come back after a reload.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft } = require("./fixtures");

test.describe("field widgets", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_widget_${stamp}`;
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

    // The fields whose rules read `kind` go first: a field other rules read can't be deleted.
    await page.goto("/editor/fields");
    for (const suffix of ["level", "extra", "kind", "flavours"]) {
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

  /** @param {import("@playwright/test").Page} page */
  async function createType(page) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Widget ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Widget ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);
  }

  /**
   * A select field from the fields admin, with its editor input chosen from
   * the widget cards, and optionally one condition authored through the
   * Conditions disclosure.
   * @param {import("@playwright/test").Page} page
   * @param {{label: string, suffix: string, options: string, widget: string, multiple?: boolean,
   *   rule?: "required_when" | "visible_when", type?: string}} field
   */
  async function addField(page, { label, suffix, options, widget, multiple, rule, type = "select" }) {
    await page.fill('#new-field-form input[name="field_definition[label]"]', label);
    await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_${suffix}`);
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', type);
    if (options) await page.fill('#new-field-form textarea[name="field_definition[options]"]', options);
    if (multiple) await page.locator("#new-field-multiple-true").check();
    if (widget) await page.locator(`#new-field-widget-${widget}`).check();

    if (rule) {
      // The disclosure keeps its state across the form's reset: open it only if it is shut.
      const disclosure = page.locator("#new-field-conditions");
      if (!(await disclosure.evaluate(el => /** @type {HTMLDetailsElement} */ (el).open))) {
        await disclosure.locator("> summary").click();
      }
      await page.locator(`#new-field-conditions-${rule}-add`).click();
      await page.selectOption(`#new-field-conditions-${rule}-row-0-field`, `${name}_kind`);
      await page.selectOption(`#new-field-conditions-${rule}-row-0-value`, "other");
    }

    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${name}_${suffix}")`)).toBeVisible();
  }

  test("a radio group is required while its rule holds, and drives another field", async ({ page }) => {
    await createType(page);
    await addField(page, { label: "Kind", suffix: "kind", options: "a\nother", widget: "radios" });
    await addField(page, { label: "Level", suffix: "level", options: "low\nhigh", widget: "radios", rule: "required_when" });
    await addField(page, { label: "Extra", suffix: "extra", type: "string", rule: "visible_when" });
    await newDraftContent(page, name);

    const kindOther = page.locator(`#custom-field-${name}_kind-opt-1`);
    const kindA = page.locator(`#custom-field-${name}_kind-opt-0`);
    const level = page.locator(`#custom-field-${name}_level`);
    const levelFirst = page.locator(`#custom-field-${name}_level-opt-0`);
    const levelHigh = page.locator(`#custom-field-${name}_level-opt-1`);
    const extraBox = page.locator(`#cf-cond-${name}_extra`);

    await expect(page.locator(`fieldset#custom-field-${name}_kind[role=radiogroup] > legend`)).toHaveText("Kind");

    // Nothing chosen: Extra hidden, Level optional (with its "— None —").
    await expect(extraBox).toBeHidden();
    await expect(levelFirst).not.toHaveJSProperty("required", true);
    await expect(level).not.toHaveAttribute("aria-required", "true");

    await kindOther.check();
    await expect(extraBox).toBeVisible();
    await expect(levelFirst).toHaveJSProperty("required", true);
    await expect(level).toHaveAttribute("aria-required", "true");
    // Required, the group loses its "— None —" with the server's next patch.
    await expect(page.locator(`#custom-field-${name}_level-opt-none`)).toHaveCount(0);

    // The browser's own validation stops a save while no level is chosen.
    expect(await levelFirst.evaluate(el => /** @type {HTMLInputElement} */ (el).form.checkValidity())).toBe(false);
    await levelHigh.check();
    expect(await levelFirst.evaluate(el => /** @type {HTMLInputElement} */ (el).form.checkValidity())).toBe(true);

    await kindA.check();
    await expect(extraBox).toBeHidden();
    await expect(levelFirst).not.toHaveJSProperty("required", true);
    await expect(level).not.toHaveAttribute("aria-required", "true");

    // Both radio groups save and come back checked.
    await saveDraft(page, { title: `Widget ${stamp}`, slug: `widget-${stamp}` });
    await page.reload();
    await expect(kindA).toBeChecked();
    await expect(levelHigh).toBeChecked();
  });

  test("checkboxes save the ticked options and show them after a reload", async ({ page }) => {
    await createType(page);
    await addField(page, {
      label: "Flavours",
      suffix: "flavours",
      options: "bitter\nsweet\nsour",
      widget: "checkboxes",
      multiple: true,
    });
    await newDraftContent(page, name);

    const box = (/** @type {number} */ i) => page.locator(`#custom-field-${name}_flavours-opt-${i}`);
    await expect(page.locator(`fieldset#custom-field-${name}_flavours > legend`)).toContainText("Flavours");

    await box(2).check();
    await box(0).check();
    await saveDraft(page, { title: `Flavours ${stamp}`, slug: `flavours-${stamp}` });

    await page.reload();
    await expect(box(0)).toBeChecked();
    await expect(box(1)).not.toBeChecked();
    await expect(box(2)).toBeChecked();

    // Unticking every box empties the field.
    await box(0).uncheck();
    await box(2).uncheck();
    await saveDraft(page, { title: `Flavours ${stamp}` });
    await page.reload();
    await expect(box(0)).not.toBeChecked();
    await expect(box(2)).not.toBeChecked();
  });
});
