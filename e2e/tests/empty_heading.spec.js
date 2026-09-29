// @ts-check
// An empty heading in a rich-text block is marked in the editor (#1728), so
// the "heading has no text" finding has something on screen to point at —
// by the advisory's own test: blank once trimmed, a hard break included.
const { test, expect, signInAsAdmin, newDraftPage, addBlock, deleteContentById } = require("./fixtures");

test.describe("empty heading marker", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("an empty heading is marked until it has text", async ({ page }) => {
    const id = await newDraftPage(page);
    try {
      await addBlock(page, "rich_text");
      const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();
      await expect(prose).toBeVisible();
      await prose.click();

      // "## " is StarterKit's heading shortcut: an empty H2.
      await page.keyboard.type("## ");
      const heading = prose.locator(":scope > h2");
      await expect(heading).toHaveClass(/is-empty-heading/);
      await expect(heading).toHaveAttribute("data-level", "2");
      const emptyHeight = (await heading.boundingBox())?.height;

      // Only a space, or only a Shift+Enter break, is still empty.
      await page.keyboard.type(" ");
      await expect(heading).toHaveClass(/is-empty-heading/);
      await page.keyboard.press("Backspace");
      await page.keyboard.press("Shift+Enter");
      await expect(heading).toHaveClass(/is-empty-heading/);

      // Text clears it, and the heading keeps its height: nothing below moves.
      await page.keyboard.press("Backspace");
      await page.keyboard.type("Intro");
      await expect(heading).not.toHaveClass(/is-empty-heading/);
      expect((await heading.boundingBox())?.height).toBe(emptyHeight);
    } finally {
      await deleteContentById(page, "page", id);
    }
  });
});
