// @ts-check
// Click-to-locate on the advisory panels: a finding in the sidebar is a
// button that scrolls the editor to what it is about and highlights it. The
// resolution logic lives in the browser (assets/js/advisory_jump.js) and reads
// the block DOM ProseMirror and LiveView render, so it can only be proven in
// a real one.
const { test, expect, signInAsAdmin, newDraftPage, addBlock } = require("./fixtures");

test.describe("advisory click-to-locate", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("clicking a missing-alt finding focuses that image's alt input", async ({ page }) => {
    await newDraftPage(page);
    // An image block counts as an image the moment it exists, so the finding
    // appears without a URL being set.
    await addBlock(page, "image");
    const block = page.locator('[data-block-type="image"]').first();
    await expect(block).toBeVisible();

    // The advisory panels live on the Settings tab of the inspector rail.
    await page.click('button[phx-click="switch_inspector_tab"][phx-value-tab="settings"]');
    const finding = page.locator(
      '#inspector-accessibility button[data-advisory-jump][data-jump-code="images_missing_alt"]',
    );
    await expect(finding).toBeVisible();

    await finding.click();

    const alt = block.locator('input[name$="[alt]"]');
    await expect(alt).toBeFocused();
    await expect(alt).toHaveClass(/kiln-issue-mark/);
    await expect(block).toHaveClass(/kiln-focus-pulse/);
    await expect(alt).toBeInViewport();

    // The highlight is temporary: typing the fix shouldn't leave a stale
    // outline behind once the finding is gone.
    await expect(alt).not.toHaveClass(/kiln-issue-mark/, { timeout: 10_000 });
  });

  test("clicking a field-level finding lands on the sidebar input", async ({ page }) => {
    await newDraftPage(page);
    await page.click('button[phx-click="switch_inspector_tab"][phx-value-tab="settings"]');

    const finding = page.locator('button[data-advisory-jump][data-jump-code="seo_description_missing"]');
    await expect(finding).toBeVisible();
    await finding.click();

    const description = page.locator('[phx-value-field="seo_description"]');
    await expect(description).toBeFocused();
    await expect(description).toBeInViewport();
  });
});
