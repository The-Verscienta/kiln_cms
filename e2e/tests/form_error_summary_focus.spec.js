// @ts-check
//
// The public form's error summary links each refusal to its field (#2268).
// Following a fragment link focuses its target only when the target can take
// focus, so a checkbox group's link points at the group's first box, not at
// its `<fieldset>`; a single-input field's link still points at the input.
// LiveViewTest checks the hrefs; only a browser moves focus, so this is where
// the focus itself is checked.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

// Adds a palette field and marks it Required, waiting for the save.
async function addRequiredField(page, type) {
  await page.locator(`button[phx-click="add_field"][phx-value-type="${type}"]`).click();
  await expect(page.locator("#fs-name")).toHaveValue(type);
  await page.locator('input[type="checkbox"][name="field[required]"]').check();
  await expect(page.locator("#field-settings-status")).toContainText("Saved.");
}

test("summary links focus a checkbox group's first box and a text input", async ({ page }) => {
  await signInAsAdmin(page);

  await page.goto("/editor/forms");
  await waitForLiveConnected(page);
  const slug = `e2e-summary-${Date.now()}`;
  await page.fill("#form-name", "E2E summary focus");
  await page.fill('input[name="form[slug]"]', slug);
  await page.locator('form[phx-submit="create_form"] button[type="submit"]').click();
  await expect(page).toHaveURL(/\/editor\/forms\/[0-9a-f-]{36}$/);
  await waitForLiveConnected(page);

  // A required group carries no per-input `required` (it would demand every
  // box), so the browser lets an empty submit through to the server.
  await addRequiredField(page, "checkboxes");
  await addRequiredField(page, "string");

  await page.goto(`/forms/${slug}`);
  const prefix = `kiln-form-${slug}`;
  // Whitespace satisfies the browser's `required`; the server trims it and
  // refuses the field, which is what puts it in the summary.
  await page.fill(`#${prefix}-string`, "   ");
  await page.locator("form.kiln-form button[type=submit]").click();

  const summary = page.locator(`#${prefix}-error-summary`);
  await expect(summary).toBeVisible();
  const links = summary.locator("a");
  await expect(links).toHaveCount(2);

  await links.nth(0).click();
  await expect(page.locator(`#${prefix}-checkboxes-0`)).toBeFocused();
  // The scroll margin keeps the group's legend on screen above its first box.
  await expect(page.locator(`#${prefix}-checkboxes legend`)).toBeInViewport();

  // Single-input fields are unchanged: the link focuses the input itself.
  await links.nth(1).click();
  await expect(page.locator(`#${prefix}-string`)).toBeFocused();
});
