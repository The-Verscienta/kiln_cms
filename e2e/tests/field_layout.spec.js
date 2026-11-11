// @ts-check
//
// Sections laid out as tabs in the Custom fields panel (#2280). What
// `FieldLayoutTest` cannot see, because it reads the server's render only:
// the arrow keys move between tabs (the shared `TabKeys` hook), a tab picked
// with a `JS` command stays picked across the patches typing brings, an
// input in an unselected tab still saves, and a required field left empty in
// an unselected tab is shown when the browser refuses the save over it
// (assets/js/reveal_invalid_field.js) rather than the Save button silently
// doing nothing.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft, holdsAcross } = require("./fixtures");

test.describe("custom field tabs", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_tabs_${stamp}`;
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

  /**
   * Add a text field to the type open in the fields admin.
   * @param {import("@playwright/test").Page} page
   * @param {string} label
   * @param {string} section
   * @param {{required?: boolean}} [opts]
   */
  async function addField(page, label, section, { required = false } = {}) {
    const field = `${name}_${label.toLowerCase()}`;
    await page.fill('#new-field-form input[name="field_definition[label]"]', label);
    await page.fill('#new-field-form input[name="field_definition[name]"]', field);
    await page.fill('#new-field-form input[name="field_definition[section]"]', section);
    if (required) await page.check('#new-field-form input[type=checkbox][name="field_definition[required]"]');
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${field}")`)).toBeVisible();
  }

  /**
   * Lay a section of the type open in the fields admin out as `display`,
   * through the fields admin's Sections panel.
   * @param {import("@playwright/test").Page} page
   * @param {string} section
   * @param {"accordion" | "fieldset" | "tab"} display
   */
  async function layOut(page, section, display) {
    // Scoped to this run's type: earlier runs leave archived types carrying
    // sections of the same names on the page.
    const row = page
      .locator(`[data-field-group="E2E Tabs ${stamp}"] [data-field-section]`)
      .filter({ hasText: section });
    await row.locator('select[name$="[display]"]').selectOption(display);
    await expect(row.locator('select[name$="[display]"]')).toHaveValue(display);
  }

  /**
   * A dynamic type whose Identity and Dosing sections are tabs.
   * @param {import("@playwright/test").Page} page
   */
  async function createType(page) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Tabs ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Tabs ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    await addField(page, "Latin", "Identity");
    await addField(page, "Notes", "Dosing");
    await layOut(page, "Identity", "tab");
    await layOut(page, "Dosing", "tab");
    return page.url();
  }

  test("arrow keys move between tabs, and the choice survives typing", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const identity = page.getByRole("tab", { name: "Identity" });
    const dosing = page.getByRole("tab", { name: "Dosing" });
    const identityPanel = page.getByRole("tabpanel", { name: "Identity" });
    const dosingPanel = page.getByRole("tabpanel", { name: "Dosing" });

    await expect(identity).toHaveAttribute("aria-selected", "true");
    await expect(identityPanel).toBeVisible();
    await expect(dosingPanel).toBeHidden();

    await identity.focus();
    await page.keyboard.press("ArrowRight");
    await expect(dosing).toBeFocused();
    await expect(dosing).toHaveAttribute("aria-selected", "true");
    await expect(dosing).toHaveAttribute("tabindex", "0");
    await expect(identity).toHaveAttribute("aria-selected", "false");
    await expect(identity).toHaveAttribute("tabindex", "-1");
    await expect(dosingPanel).toBeVisible();
    await expect(identityPanel).toBeHidden();

    // Wraps at the ends; Home and End jump there.
    await page.keyboard.press("ArrowRight");
    await expect(identity).toBeFocused();
    await expect(identity).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("End");
    await expect(dosing).toBeFocused();
    await page.keyboard.press("Home");
    await expect(identity).toBeFocused();
    await page.keyboard.press("ArrowLeft");
    await expect(dosing).toHaveAttribute("aria-selected", "true");

    // Every keystroke in the form is a patch of the panel; the tab stays picked.
    await page.locator(`#custom-field-${name}_notes`).pressSequentially("Twice a day");
    await page.locator('input[name$="[title]"]').pressSequentially("typing patches");
    await holdsAcross(
      page,
      async () => ({
        selected: await dosing.getAttribute("aria-selected"),
        shown: await dosingPanel.isVisible(),
        other: await identityPanel.isVisible(),
      }),
      { selected: "true", shown: true, other: false }
    );
  });

  test("an input in an unselected tab still saves", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    await page.getByRole("tab", { name: "Dosing" }).click();
    await page.locator(`#custom-field-${name}_notes`).fill("With food");
    await page.getByRole("tab", { name: "Identity" }).click();
    await expect(page.locator(`#custom-field-${name}_notes`)).toBeHidden();

    await saveDraft(page, { title: `Tabs ${stamp}`, slug: `tabs-${stamp}` });
    await page.reload();
    await expect(page.locator(`#custom-field-${name}_notes`)).toHaveValue("With food");
  });

  test("a required field left empty in an unselected tab is shown on save", async ({ page }) => {
    const fieldsUrl = await createType(page);
    const id = await newDraftContent(page, name);
    await saveDraft(page, { title: `Tabs ${stamp}`, slug: `tabs-${stamp}` });

    // Required only once the record exists, so the draft could be created.
    await page.goto(fieldsUrl);
    await addField(page, "Dose", "Dosing", { required: true });
    await page.goto(`/editor/content/${name}/${id}`);

    const dosing = page.getByRole("tab", { name: "Dosing" });
    const dose = page.locator(`#custom-field-${name}_dose`);
    await expect(page.getByRole("tab", { name: "Identity" })).toHaveAttribute("aria-selected", "true");
    await expect(dose).toBeHidden();
    await expect(dose).toHaveJSProperty("required", true);

    // The browser refuses the save; its message needs the field on screen.
    await page.getByRole("button", { name: /^save draft$/i }).click();
    await expect(dosing).toHaveAttribute("aria-selected", "true");
    await expect(dose).toBeVisible();
    await expect(dose).toBeFocused();
    expect(await dose.evaluate(el => /** @type {HTMLInputElement} */ (el).validity.valueMissing)).toBe(true);

    // It stays shown through the patches typing brings, and then saves.
    await dose.pressSequentially("3 g");
    await holdsAcross(page, async () => await dose.isVisible(), true);
    await saveDraft(page, { title: `Tabs ${stamp}`, slug: `tabs-${stamp}` });
    await page.reload();
    await expect(page.locator(`#custom-field-${name}_dose`)).toHaveValue("3 g");
  });
});
