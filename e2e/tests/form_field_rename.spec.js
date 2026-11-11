// @ts-check
//
// Renaming a form field's machine name (#2139). The settings panel saves on
// change, but the machine-name input only fires on blur, so Enter used to do
// nothing at all: no submit handler and no submit button meant implicit
// submission was a no-op, and a reload showed the old name. The panel now has
// a Save button and `phx-submit`, so Enter saves. LiveViewTest can't press
// Enter in a real input, so this is where that path is exercised.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

test("Enter in the machine-name input saves the rename", async ({ page }) => {
  await signInAsAdmin(page);

  await page.goto("/editor/forms");
  const slug = `e2e-rename-${Date.now()}`;
  await page.fill("#form-name", "E2E rename");
  await page.fill('input[name="form[slug]"]', slug);
  await page.locator('form[phx-submit="create_form"] button[type="submit"]').click();
  await expect(page).toHaveURL(/\/editor\/forms\/[0-9a-f-]{36}$/);
  await waitForLiveConnected(page);
  const builderUrl = page.url();

  await page.locator('button[phx-click="add_field"][phx-value-type="string"]').click();
  const name = page.locator("#fs-name");
  await expect(name).toHaveValue("string");

  await name.fill("full_name");
  await name.press("Enter");

  await expect(page.locator("#field-settings-status")).toContainText("Saved.");
  await expect(page.locator('[id^="canvas-field-name-"]')).toHaveText("full_name");

  await page.goto(builderUrl);
  await page.locator('button[phx-click="select_field"]').first().click();
  await expect(page.locator("#fs-name")).toHaveValue("full_name");
});
