// @ts-check
// The Branding page (#1810, #1811), in a real browser: a saved brand colour
// repaints the console's own buttons without a manual reload, and an image
// field can be filled by uploading a file right there.
const {test, expect, signInAsAdmin} = require("./fixtures");

// A minimal valid 1x1 PNG (the same bytes the Elixir tests upload).
const PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP6zwAAAAcAAQL+pTXmAAAAAElFTkSuQmCC";

test.use({colorScheme: "light"});

test.describe("branding", () => {
  test.beforeEach(async ({page}) => {
    await signInAsAdmin(page);
    await page.goto("/editor/branding");
    await expect(page.locator("#branding-form")).toBeVisible();
  });

  // Leave the shared e2e site on its stock branding for the other specs.
  test.afterEach(async ({page}) => {
    await page.goto("/editor/branding");
    const reset = page.getByRole("button", {name: "Reset to defaults"});
    if (await reset.count()) {
      page.once("dialog", dialog => dialog.accept());
      await reset.click();
      await expect(page.getByText("Branding reset to the site defaults.")).toBeVisible();
    }
  });

  test("a saved colour repaints the console's buttons without a manual reload", async ({page}) => {
    const save = page.getByRole("button", {name: "Save branding"});
    const background = () => save.evaluate(el => getComputedStyle(el).backgroundColor);
    const before = await background();

    await page.locator("#branding_brand_color").fill("#0f62fe");
    // The preview predicts the exact fill Save will apply.
    const swatch = page.locator("#brand-preview-light span", {hasText: "Button"});
    await expect(swatch).toBeVisible();
    const predicted = await swatch.evaluate(el => getComputedStyle(el).backgroundColor);
    expect(predicted).not.toEqual(before);

    await save.click();
    await expect(page.getByText("Branding saved.")).toBeVisible();

    // No page.reload() here: that is the bug this guards.
    await expect.poll(background).toEqual(predicted);
  });

  test("an uploaded logo fills the field and shows a thumbnail", async ({page}) => {
    const input = page.locator("#image-field-logo_url input[type=file]");
    await input.setInputFiles({
      name: "e2e-logo.png",
      mimeType: "image/png",
      buffer: Buffer.from(PNG_BASE64, "base64"),
    });

    await expect(page.locator("#branding_logo_url")).toHaveValue(/\/uploads\//);
    await expect(page.locator("#image-field-logo_url-preview")).toHaveAttribute("src", /\/uploads\//);
  });
});
