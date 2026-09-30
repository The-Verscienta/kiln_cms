// @ts-check
// Editing in place can add a block where the author is looking (#1801): the
// "Add a block" control opens a menu, the chosen block appears focused, and
// what is typed into it is saved with the page.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  saveDraft,
  deleteContentById,
} = require("./fixtures");

test.describe("in-place add block", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("an added heading takes focus and is saved with the page", async ({ page }) => {
    const id = await newDraftPage(page);
    const slug = `e2e-add-block-${Date.now()}`;
    try {
      await saveDraft(page, { title: "Add block in place", slug });

      await page.goto(`/editor/site/page/${slug}`);
      await expect(page.locator("#in-context-edit-bar")).toBeVisible();
      await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);

      await page.click("#add-block-end");
      const menu = page.locator("#add-menu-end");
      await expect(menu).toBeVisible();
      await menu.getByRole("button", { name: "Heading" }).click();

      // The new heading is focused, so typing goes straight into it.
      const heading = page.locator('h2[phx-hook="InlineText"]');
      await expect(heading).toHaveCount(1);
      await expect(heading).toBeFocused();
      await page.keyboard.type("Typed in place");
      await heading.blur();

      await page.locator("#in-context-edit-bar").getByRole("button", { name: "Save" }).click();
      await expect(page.locator("#in-context-save-state")).toHaveAttribute("data-state", "saved");

      // Reload: the heading came from the database, not the DOM.
      await page.reload();
      await expect(page.locator('h2[phx-hook="InlineText"]')).toHaveText("Typed in place");
    } finally {
      await deleteContentById(page, "page", id);
    }
  });
});
