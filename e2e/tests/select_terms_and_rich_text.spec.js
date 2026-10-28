// @ts-check
//
// A `:select` holding several terms (the `TermPicker` hook: Enter and comma
// add, Backspace in an empty box removes the last chip, a drag reorders) and a
// rich `:text` field (the `RichTextField` hook: TipTap over a hidden input,
// toolbar buttons, the HTML saved). `SelectAndTextFieldEditorTest` pushes the
// picker's events and posts the hidden input itself, which proves what the
// server does with them and nothing about whether the hooks send them.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft } = require("./fixtures");

test.describe("select terms and rich text fields", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_terms_${stamp}`;
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
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Terms ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Terms ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    // Several terms, open vocabulary.
    await page.fill('#new-field-form input[name="field_definition[label]"]', "Properties");
    await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_props`);
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "select");
    await page.locator("#new-field-multiple-true").check();
    await page.locator("#new-field-multiple-allow-custom").check();
    await page.fill('#new-field-form textarea[name="field_definition[options]"]', "adaptogen\ntonic");
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${name}_props")`)).toBeVisible();

    // Rich text is the default for :text.
    await page.fill('#new-field-form input[name="field_definition[label]"]', "Uses");
    await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_uses`);
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "text");
    await expect(page.locator("#new-field-format-rich")).toBeChecked();
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator(`code:text-is("${name}_uses")`)).toBeVisible();
  }

  test("terms are added, removed and reordered; rich text saves its HTML", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const props = `${name}_props`;
    const entry = page.locator(`#custom-field-${props}-entry`);
    const chips = page.locator(`#custom-field-${props}-terms > li`);
    const terms = () => chips.locator("input[type=hidden]").evaluateAll(els => els.map(el => /** @type {HTMLInputElement} */ (el).value));

    await entry.fill("tonic");
    await entry.press("Enter");
    await expect.poll(terms).toEqual(["tonic"]);

    // A comma adds too, and a typed list splits.
    await entry.fill("nervine, adaptogen");
    await entry.press(",");
    await expect.poll(terms).toEqual(["tonic", "nervine", "adaptogen"]);
    await expect(entry).toHaveValue("");

    // Backspace in the empty box drops the last chip.
    await entry.press("Backspace");
    await expect.poll(terms).toEqual(["tonic", "nervine"]);

    // Drag "nervine" above "tonic".
    await chips.nth(1).locator("[data-drag-handle]").dragTo(chips.nth(0), { targetPosition: { x: 4, y: 4 } });
    await expect.poll(terms).toEqual(["nervine", "tonic"]);

    // The rich text field: type, bold a word with the toolbar.
    const uses = page.locator(`#cf-rich-${name}_uses`);
    const editor = uses.locator(".ProseMirror");
    await expect(editor).toBeVisible();
    await editor.click();
    await page.keyboard.type("Calms the ");
    await uses.getByRole("button", { name: "Bold (⌘B)" }).click();
    await page.keyboard.type("shen");
    await expect(editor.locator("strong")).toHaveText("shen");

    const hidden = uses.locator("input[data-field-value]");
    await expect(hidden).toHaveValue("<p>Calms the <strong>shen</strong></p>");

    await saveDraft(page, { title: `Terms ${stamp}`, slug: `terms-${stamp}` });
    await page.reload();

    await expect.poll(terms).toEqual(["nervine", "tonic"]);
    await expect(page.locator(`#cf-rich-${name}_uses .ProseMirror strong`)).toHaveText("shen");
  });
});
