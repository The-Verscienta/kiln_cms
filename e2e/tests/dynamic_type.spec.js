// @ts-check
//
// Dynamic content types (#1314): define a type in the browser, give it a
// custom field, and author a draft of it — the new type must show up in the
// content list's "New …" menu, the editor must render the field, and the
// value must survive a save + reload. Then archive the type again.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftContent,
  deleteContentById,
} = require("./fixtures");

test.describe("dynamic content types", () => {
  const stamp = Date.now();
  const label = `E2E Recipe ${stamp}`;
  const name = `e2e_recipe_${stamp}`;
  const fieldName = `chef_${stamp}`;
  /** @type {string | null} */
  let draftId = null;

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Best-effort cleanup: the draft (if the journey got that far), then the
    // type itself — archived, which is what the UI offers, and enough to take
    // it out of every later spec's "New …" menu.
    if (draftId) {
      await deleteContentById(page, name, draftId);
      draftId = null;
    }
    await page.goto("/editor/types");
    const row = page.locator("li[id^='type-']").filter({ hasText: name });
    if (await row.count()) {
      page.once("dialog", dialog => dialog.accept());
      await row.getByRole("button", { name: "Archive content type" }).click();
      await expect(page.locator("#flash-info")).toContainText("Content type archived.");
      await expect(row).toHaveCount(0);
    }
  });

  test("define a type → add a field → author a draft of it → archive it", async ({ page }) => {
    // Define the type. Machine name is what the URL and the "new" handler use.
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', label);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `${label}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page.locator("#flash-info")).toContainText("Content type created. Now add its fields.");
    const typeRow = page.locator("li[id^='type-']").filter({ hasText: name });
    await expect(typeRow).toBeVisible();
    await expect(typeRow).toContainText("0 fields");
    // The URL segment defaults to machine name + "s".
    await expect(typeRow).toContainText(`/${name}s`);

    // Give it a string field, scoped to the new type via the "Custom" group.
    await page.goto("/editor/fields");
    await page.selectOption("#new-field-scope", { label });
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "string");
    await page.fill('#new-field-form input[name="field_definition[label]"]', "Chef");
    await page.fill('#new-field-form input[name="field_definition[name]"]', fieldName);
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator("#flash-info")).toContainText("Field added.");
    await page.goto("/editor/types");
    await expect(typeRow).toContainText("1 field");

    // The content list now offers "New e2e recipe …" and the editor opens on
    // /editor/content/<name>/<id> with the custom field rendered.
    await newDraftContent(page, name);
    draftId = page.url().split("/").pop() ?? null;
    expect(page.url()).toContain(`/editor/content/${name}/`);
    // Custom fields sit in the inspector rail's Settings panel (with SEO and
    // Organization), which is CSS-hidden behind the default Preview tab.
    const settingsTab = page.getByRole("tab", { name: /settings/i });
    const chef = page.locator(`#custom-field-${fieldName}`);
    await expect(chef).toBeHidden();
    await settingsTab.click();
    await expect(chef).toBeVisible();

    const title = `E2E Recipe Draft ${stamp}`;
    await page.fill('input[name$="[title]"]', title);
    await page.fill('input[name$="[slug]"]', `e2e-recipe-draft-${stamp}`);
    await chef.fill("Auguste Escoffier");
    await page.getByRole("button", { name: /^save$/i }).click();
    await expect(page.locator('input[name$="[title]"]')).toHaveValue(title);

    // Persisted: a full reload renders the saved value from the record.
    await page.reload();
    await expect(page.locator('input[name$="[title]"]')).toHaveValue(title);
    await settingsTab.click();
    await expect(chef).toBeVisible();
    await expect(chef).toHaveValue("Auguste Escoffier");

    // And the list shows the draft under its own kind.
    await page.goto(`/editor?q=${encodeURIComponent(title)}`);
    const listRow = page.locator(`li[id="${name}-${draftId}"]`);
    await expect(listRow).toBeVisible();
    await expect(listRow).toContainText(name);
  });
});
