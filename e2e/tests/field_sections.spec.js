// @ts-check
//
// Sections in the Custom fields panel: a heading toggles its fields, and the
// state the writer leaves it in survives the LiveView patches that typing
// into another field brings — the toggle is a `JS` command, kept across
// patches, which `FieldSectionsTest` cannot see (it reads the server's render
// only). Expand all / Collapse all act on every section at once.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft } = require("./fixtures");

test.describe("custom field sections", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_sections_${stamp}`;
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
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Sections ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Sections ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    for (const [label, section] of [["Latin", "Identity"], ["Caution", "Safety"]]) {
      await page.fill('#new-field-form input[name="field_definition[label]"]', label);
      await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_${label.toLowerCase()}`);
      await page.fill('#new-field-form input[name="field_definition[section]"]', section);
      await page.locator("#new-field-form button[type=submit]").click();
      await expect(page.locator(`code:text-is("${name}_${label.toLowerCase()}")`)).toBeVisible();
    }
  }

  test("a section toggles, and stays as left while another field is typed into", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const identity = page.locator("#cf-section-0-toggle");
    const identityBody = page.locator("#cf-section-0-body");
    const safety = page.locator("#cf-section-1-toggle");
    const safetyBody = page.locator("#cf-section-1-body");
    const latin = page.locator(`#custom-field-${name}_latin`);

    // A new record: the first section is open, the next closed.
    await expect(identity).toHaveAttribute("aria-expanded", "true");
    await expect(identityBody).toBeVisible();
    await expect(safetyBody).toBeHidden();

    // Open Safety, then type into Identity: every keystroke patches the panel.
    await safety.click();
    await expect(safety).toHaveAttribute("aria-expanded", "true");
    await expect(safetyBody).toBeVisible();

    await latin.pressSequentially("Panax ginseng");
    await expect(page.locator("#cf-section-0-toggle")).toContainText("1 of 1 filled");
    await expect(safetyBody).toBeVisible();

    // Collapse Identity while its field holds a value; typing elsewhere keeps it closed.
    await identity.click();
    await expect(identityBody).toBeHidden();
    await page.locator(`#custom-field-${name}_caution`).pressSequentially("Pregnancy");
    await expect(identityBody).toBeHidden();
    await expect(identity).toHaveAttribute("aria-expanded", "false");

    await page.locator("#cf-sections-expand").click();
    await expect(identityBody).toBeVisible();
    await expect(safetyBody).toBeVisible();
    await page.locator("#cf-sections-collapse").click();
    await expect(identityBody).toBeHidden();
    await expect(safetyBody).toBeHidden();

    // A collapsed section's inputs still save.
    await saveDraft(page, { title: `Sections ${stamp}`, slug: `sections-${stamp}` });
    await page.reload();
    await expect(page.locator(`#custom-field-${name}_latin`)).toHaveValue("Panax ginseng");
    await expect(page.locator(`#custom-field-${name}_caution`)).toHaveValue("Pregnancy");
  });
});
