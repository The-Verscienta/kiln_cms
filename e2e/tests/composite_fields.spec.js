// @ts-check
//
// The range, key/value and link field widgets (#2278, #2435) in a real
// browser. The ExUnit tests prove the markup and the write path; only a
// browser shows the blank-first "Opens in" select posting and restoring, the
// key/value textarea round-tripping, and the part help lines being rendered
// beside (and described to) the controls they explain.
const { test, expect, signInAsAdmin, newDraftContent, saveDraft } = require("./fixtures");

test.describe("composite field widgets", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_composite_${stamp}`;
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

    await page.goto("/editor/fields");
    for (const suffix of ["band", "specs", "source"]) {
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

  test("range, key/value and link save, restore and explain themselves", async ({ page }) => {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Composite ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Composite ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    for (const [suffix, label, type] of [
      ["band", "Band", "range"],
      ["specs", "Specs", "key_value"],
      ["source", "Source", "link"],
    ]) {
      await page.fill('#new-field-form input[name="field_definition[label]"]', label);
      await page.fill('#new-field-form input[name="field_definition[name]"]', `${name}_${suffix}`);
      await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', type);
      await page.locator("#new-field-form button[type=submit]").click();
      await expect(page.locator(`code:text-is("${name}_${suffix}")`)).toBeVisible();
    }

    await newDraftContent(page, name);

    const max = page.locator(`#custom-field-${name}_band-max`);
    const rel = page.locator(`#custom-field-${name}_source-rel`);
    await expect(page.locator(`#custom-field-${name}_band-max-help`)).toContainText("The same kind as From");
    await expect(max).toHaveAttribute("aria-describedby", `custom-field-${name}_band-max-help`);
    await expect(page.locator(`#custom-field-${name}_source-rel-help`)).toContainText("Space-separated");
    await expect(rel).toHaveAttribute("aria-describedby", `custom-field-${name}_source-rel-help`);

    await page.fill(`#custom-field-${name}_band-min`, "5");
    await max.fill("9");
    await page.fill(`#custom-field-${name}_specs`, "Weight=2 kg\nColor=red");
    await page.fill(`#custom-field-${name}_source-url`, "https://example.com/a");
    await page.selectOption(`#custom-field-${name}_source-target`, "_blank");
    await saveDraft(page, { title: `Composite ${stamp}`, slug: `composite-${stamp}` });

    await page.reload();
    await expect(page.locator(`#custom-field-${name}_band-min`)).toHaveValue("5");
    await expect(max).toHaveValue("9");
    await expect(page.locator(`#custom-field-${name}_specs`)).toHaveValue("Weight=2 kg\nColor=red");
    await expect(page.locator(`#custom-field-${name}_source-url`)).toHaveValue("https://example.com/a");
    await expect(page.locator(`#custom-field-${name}_source-target`)).toHaveValue("_blank");

    // A hostile address is refused and the typed text stays.
    await page.fill(`#custom-field-${name}_source-url`, "javascript:alert(1)");
    await page.locator('form[id$="-editor"] button[type=submit]').first().click();
    await expect(page.locator(`#custom-field-${name}_source-url`)).toHaveValue("javascript:alert(1)");
    await page.screenshot({ path: process.env.COMPOSITE_SHOT || "test-results/composite.png", fullPage: true });
  });
});
