// @ts-check
// The caret survives the first autosave of a just-added block.
//
// Adding a block extends the form in memory; the draft's first autosave then
// rebuilds the form from the saved record. If that rebuild changes what sits
// ahead of the block's card inside #blocks-sortable, morphdom detaches and
// re-attaches the card to put it back in place, and a detached focused
// element loses focus — the author's next keystrokes go to <body>. The card
// must therefore keep its position across the rebuild; this spec types
// straight through the save without clicking back in.
const {test, expect, signInAsAdmin, newDraftPage, addBlock} = require("./fixtures");

test.describe("focus across the first autosave", () => {
  test.beforeEach(async ({page}) => {
    await signInAsAdmin(page);
  });

  test("a rich-text block keeps the caret through its first autosave", async ({page}) => {
    await newDraftPage(page);
    await addBlock(page, "rich_text");
    const editor = page.locator('[phx-hook="RichText"] .ProseMirror').first();
    await editor.click();
    await page.keyboard.type("Before the save. ");

    // The autosave lands: the save line flashes "Saved" once the patch that
    // rebuilt the form has been applied (the ticker runs after the patch).
    const status = page.locator("#save-status");
    await expect(status).toHaveClass(/fresh/, {timeout: 5000});
    const writtenAt = await status.getAttribute("data-at");

    // No click back in: the caret must still be where the author left it.
    expect(
      await page.evaluate(() => document.activeElement?.classList.contains("ProseMirror"))
    ).toBe(true);
    await page.keyboard.type("After the save.");
    await expect(editor).toHaveText("Before the save. After the save.");

    // And the block card is still the sortable's first child — nothing crept
    // in ahead of it on the rebuilt form.
    const cards = page.locator("#blocks-sortable > *");
    await expect(cards).toHaveCount(1);
    await expect(cards.first()).toHaveAttribute("id", "block-0");

    // The words typed after the save reach the record: the next autosave
    // moves the stamp, and a fresh load shows both halves.
    await expect(status).not.toHaveAttribute("data-at", writtenAt || "", {timeout: 10000});
    await page.reload();
    await expect(page.locator('[phx-hook="RichText"] .ProseMirror').first()).toHaveText(
      "Before the save. After the save."
    );
  });
});
