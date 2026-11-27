// @ts-check
//
// Conditional fields on a public form (#2262). The builder saves a rule on
// an earlier field; the public page's form script then shows the field only
// while the rule holds, and a hidden required field never blocks the submit.
// With JavaScript off every field is shown, none is browser-required, and
// the server still drops what the hidden field sent. LiveViewTest covers the
// markup and the server; only a browser runs the script.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

// A form with a dropdown (`Option 1` / `Option 2`) and, after it, a required
// text field shown only while the dropdown is `Option 1`. Returns its slug.
async function conditionalForm(page) {
  await signInAsAdmin(page);
  await page.goto("/editor/forms");
  await waitForLiveConnected(page);
  const slug = `e2e-conditions-${Date.now()}`;
  await page.fill("#form-name", "E2E conditions");
  await page.fill('input[name="form[slug]"]', slug);
  await page.locator('form[phx-submit="create_form"] button[type="submit"]').click();
  await expect(page).toHaveURL(/\/editor\/forms\/[0-9a-f-]{36}$/);
  await waitForLiveConnected(page);

  await page.locator('button[phx-click="add_field"][phx-value-type="select"]').click();
  await expect(page.locator("#fs-name")).toHaveValue("select");

  await page.locator('button[phx-click="add_field"][phx-value-type="string"]').click();
  await expect(page.locator("#fs-name")).toHaveValue("string");
  await page.locator('input[type="checkbox"][name="field[required]"]').check();
  await expect(page.locator("#field-settings-status")).toContainText("Saved.");

  // The new row tests the only earlier field, against its first option.
  await page.getByRole("button", { name: "Add a condition" }).click();
  await expect(page.locator("#fs-condition-status")).toContainText("Saved.");
  await expect(page.locator("#fs-condition-value-0")).toHaveValue("Option 1");

  return slug;
}

test("a field shows only while its rule holds, and a hidden required field doesn't block", async ({ page }) => {
  const slug = await conditionalForm(page);
  const prefix = `kiln-form-${slug}`;

  await page.goto(`/forms/${slug}`);
  const form = page.locator("form.kiln-form");
  await expect(form).toHaveAttribute("data-kiln-enhanced", "");

  const wrapper = page.locator('[data-kiln-field="string"]');
  const input = page.locator(`#${prefix}-string`);
  await expect(wrapper).toBeHidden();
  await expect(input).toBeDisabled();
  await expect(page.locator(".kiln-form-condition-hint")).toBeHidden();

  await page.selectOption(`#${prefix}-select`, "Option 1");
  await expect(wrapper).toBeVisible();
  await expect(input).toHaveAttribute("required", "");

  // Shown and required: the browser holds the submit.
  await form.locator("button[type=submit]").click();
  await expect(page).toHaveURL(new RegExp(`/forms/${slug}$`));
  await expect(input).toBeFocused();

  // Hidden again: the empty required field no longer blocks, and isn't sent.
  await input.fill("typed while shown");
  await page.selectOption(`#${prefix}-select`, "Option 2");
  await expect(wrapper).toBeHidden();

  const posted = page.waitForRequest((r) => r.method() === "POST" && r.url().includes(`/forms/${slug}`));
  await form.locator("button[type=submit]").click();
  const body = (await posted).postData() || "";
  expect(body).toContain("select=Option+2");
  expect(body).not.toContain("string=");
  await expect(page.getByRole("heading", { name: /thank/i })).toBeVisible();
});

test("with JavaScript off every field is shown and the server decides", async ({ page, browser }) => {
  const slug = await conditionalForm(page);
  const prefix = `kiln-form-${slug}`;

  const context = await browser.newContext({ javaScriptEnabled: false, baseURL: page.url().replace(/\/editor.*$/, "") });
  const visitor = await context.newPage();
  await visitor.goto(`/forms/${slug}`);

  await expect(visitor.locator(`#${prefix}-string`)).toBeVisible();
  await expect(visitor.locator(".kiln-form-condition-hint")).toBeVisible();
  // No browser `required` on a field that may not apply.
  await expect(visitor.locator(`#${prefix}-string`)).not.toHaveAttribute("required", "");

  // The rule hides the field for this answer, so its empty required value is
  // accepted and anything typed is dropped.
  await visitor.selectOption(`#${prefix}-select`, "Option 2");
  await visitor.fill(`#${prefix}-string`, "not needed");
  await visitor.locator("form.kiln-form button[type=submit]").click();
  await expect(visitor.getByRole("heading", { name: /thank/i })).toBeVisible();

  await context.close();
});
