// @ts-check
//
// The field-definitions sync screen (#2438) in a real browser: a file is
// chosen, previewed (nothing written), and applied only after the explicit
// confirm step; the prune and data-loss confirmations are separate controls.
const { test, expect, signInAsAdmin } = require("./fixtures");

test.describe("field definition sync screen", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("preview writes nothing; apply needs the confirm step", async ({ page }) => {
    const name = `e2e_sync_${Date.now()}`;
    const doc = {
      format: "kiln-field-definitions",
      version: 1,
      owners: [
        {
          kind: "compiled",
          type: "post",
          fields: [{ name, label: "E2E sync", field_type: "string" }],
        },
      ],
    };

    await page.goto("/editor/fields");
    await page.getByRole("link", { name: "Sync definitions from a file" }).click();
    await expect(page.getByRole("heading", { name: "Sync field definitions", level: 1 })).toBeVisible();
    await page.waitForSelector("[data-phx-main].phx-connected");

    await page.getByLabel(/Field definitions file/).setInputFiles({
      name: "fields.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(doc)),
    });
    await page.getByRole("button", { name: "Preview changes" }).click();

    const diff = page.locator("#sync-diff");
    await expect(diff).toContainText(`post.${name}`);
    await expect(diff).toContainText("Create");
    await expect(page.locator("#sync-confirm")).toHaveCount(0);

    // The two confirmations are separate, unchecked controls.
    await expect(page.getByLabel("Delete fields this file does not list")).not.toBeChecked();
    await expect(page.getByLabel(/Allow changes that drop values/)).not.toBeChecked();

    await page.getByRole("button", { name: "Apply…" }).click();
    await expect(page.locator("#sync-confirm")).toBeVisible();
    await page.getByRole("button", { name: "Yes, apply these changes" }).click();
    await expect(page.locator("#sync-applied")).toContainText("1 created");

    // Clean up through the fields screen.
    await page.goto("/editor/fields");
    const field = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${name}")`) });
    await expect(field).toHaveCount(1);
    page.once("dialog", dialog => dialog.accept());
    await field.getByRole("button", { name: "Delete field", exact: true }).click();
    await expect(field).toHaveCount(0);
  });
});
