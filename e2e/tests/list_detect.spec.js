// @ts-check
// A rich-text block recognises lists the author didn't mark up as lists:
// typed with a "•" or "1)", pasted as bullet characters, or pasted out of
// Word — whose HTML has no <ul>/<ol>, only `mso-list` paragraphs.
const { test, expect, signInAsAdmin, newDraftPage, addBlock, deleteContentById } = require("./fixtures");

// A real `paste` event carrying the given clipboard types (see
// markdown.spec.js for why it is synthetic).
async function paste(locator, types) {
  await locator.evaluate((el, entries) => {
    const data = new DataTransfer();
    for (const [type, value] of entries) data.setData(type, value);
    el.dispatchEvent(
      new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }),
    );
  }, Object.entries(types));
}

// The shape Word puts on the clipboard for a two-level bulleted list followed
// by a numbered one (trimmed: the real thing carries far more styling).
const WORD_HTML = `<html xmlns:o="urn:schemas-microsoft-com:office:office"><body>
<p class=MsoListParagraphCxSpFirst style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol'><span style='mso-list:Ignore'>·<span>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span></span></span><![endif]>Flour<o:p></o:p></p>
<p class=MsoListParagraphCxSpMiddle style='margin-left:1.0in;text-indent:-.25in;mso-list:l0 level2 lfo1'><![if !supportLists]><span style='font-family:"Courier New"'><span style='mso-list:Ignore'>o<span>&nbsp;&nbsp;</span></span></span><![endif]>Sifted<o:p></o:p></p>
<p class=MsoListParagraphCxSpLast style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol'><span style='mso-list:Ignore'>·<span>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</span></span></span><![endif]>Water<o:p></o:p></p>
<p class=MsoNormal>Then:</p>
<p class=MsoListParagraphCxSpFirst style='text-indent:-.25in;mso-list:l1 level1 lfo2'><![if !supportLists]><span><span style='mso-list:Ignore'>1.<span>&nbsp;&nbsp;&nbsp;</span></span></span><![endif]>Mix<o:p></o:p></p>
<p class=MsoListParagraphCxSpLast style='text-indent:-.25in;mso-list:l1 level1 lfo2'><![if !supportLists]><span><span style='mso-list:Ignore'>2.<span>&nbsp;&nbsp;&nbsp;</span></span></span><![endif]>Bake<o:p></o:p></p>
</body></html>`;

test.describe("list detection", () => {
  test.beforeEach(async ({ page, browserName }) => {
    test.skip(browserName === "webkit", "synthetic clipboardData is Chromium-only");
    await signInAsAdmin(page);
  });

  test("typed and pasted lists become real lists", async ({ page }) => {
    const id = await newDraftPage(page);
    try {
      await addBlock(page, "rich_text");
      const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();
      await expect(prose).toBeVisible();
      await prose.click();

      // Typed: "• " starts a bullet list, "1) " a numbered one.
      await page.keyboard.type("• apples");
      await expect(prose.locator("ul > li")).toHaveText(["apples"]);
      await page.keyboard.press("Enter");
      await page.keyboard.press("Enter");
      await page.keyboard.type("1) first");
      await expect(prose.locator("ol > li")).toHaveText(["first"]);
      await page.keyboard.press("Enter");
      await page.keyboard.press("Enter");

      // Plain text with bullet characters — a PDF, an email. The markers go;
      // it isn't Markdown, so no conversion notice.
      await paste(prose, { "text/plain": "• one\n• two\n• three" });
      await expect(prose.locator("ul > li")).toHaveText(["apples", "one", "two", "three"]);
      await expect(prose).not.toContainText("•");
      await expect(page.locator(".rt-paste-notice")).toBeHidden();
    } finally {
      await deleteContentById(page, "page", id);
    }
  });

  test("a list pasted from Word keeps its nesting and numbering", async ({ page }) => {
    const id = await newDraftPage(page);
    try {
      await addBlock(page, "rich_text");
      const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();
      await expect(prose).toBeVisible();
      await prose.click();

      await paste(prose, { "text/html": WORD_HTML, "text/plain": "· Flour\no Sifted\n· Water" });

      await expect(prose.locator(":scope > ul > li")).toHaveCount(2);
      await expect(prose.locator(":scope > ul > li").first()).toContainText("Flour");
      await expect(prose.locator(":scope > ul > li > ul > li")).toHaveText(["Sifted"]);
      await expect(prose.locator(":scope > ol > li")).toHaveText(["Mix", "Bake"]);
      await expect(prose.locator(":scope > p")).toContainText(["Then:"]);
      // Word's own markers are gone.
      await expect(prose).not.toContainText("·");
    } finally {
      await deleteContentById(page, "page", id);
    }
  });
});
