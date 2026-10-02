// @ts-check
// Faceted, saved views on the content list (#1593).
//
// The LiveView tests cover each facet and the policy; this is the journey in a
// real browser: narrow the list through the facet panel, watch the URL follow,
// save the result under a name with the keyboard, and find it marked as the
// current view after a reload — the URL alone has to carry it.
const { test, expect, signInAsEditor } = require("./fixtures");

test.describe("content list views", () => {
  test.use({ viewport: { width: 1280, height: 900 } });

  test("filter, save the view, and find it again after a reload", async ({ page }, testInfo) => {
    await signInAsEditor(page);
    const name = `Mine A-Z ${Date.now()}`;

    await page.goto("/editor?status=draft");
    await expect(page.locator("#content-views")).toBeVisible();

    // The facet panel opens from its toggle, which says whether it is open.
    const toggle = page.locator("#toggle-filters");
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");

    await page.locator("#content-author-filter").selectOption("me");
    await expect(page).toHaveURL(/author=me/);
    await page.locator("#content-sort").selectOption("title");
    await expect(page).toHaveURL(/sort=title/);
    await expect(page).toHaveURL(/status=draft/);

    // One chip per facet, each a labelled remove button.
    await expect(page.getByRole("button", { name: "Remove filter: Author: me" })).toBeVisible();

    await page.locator("#save-view").click();
    const field = page.locator("#save-view-name");
    await expect(field).toBeFocused();
    await field.fill(name);
    await field.press("Enter");

    const view = page.locator("#content-views a", { hasText: name });
    await expect(view).toHaveAttribute("aria-current", "page");
    await page.screenshot({ path: testInfo.outputPath("content-views-saved.png") });

    try {
      await page.reload();
      await expect(view).toHaveAttribute("aria-current", "page");

      // Another view takes the mark away, and the back button brings it back.
      await page.locator("#view-needs-review").click();
      await expect(page).toHaveURL(/status=in_review/);
      await expect(view).not.toHaveAttribute("aria-current", "page");
      await page.goBack();
      await expect(view).toHaveAttribute("aria-current", "page");
    } finally {
      // The e2e database is persistent: leave no view behind.
      await view.click();
      await page.getByRole("button", { name: "Delete view" }).click();
      await page.locator("#delete-view-confirm").getByRole("button", { name: "Delete view" }).click();
      await expect(page.locator("#content-views a", { hasText: name })).toHaveCount(0);
    }
  });
});
