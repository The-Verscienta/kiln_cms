// @ts-check
// Markdown in the content editor: pasted into a rich-text block it lands as
// structure — with Undo and "Paste as plain text" one click away — and a
// `.md` file imported through "Import Markdown" lands as typed blocks plus the
// title it names, which a Save persists. The Blocks | Markdown switch shows
// the body as Markdown, and what is pasted there comes back as blocks.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  addBlock,
  save,
  deleteContentById,
} = require("./fixtures");

// Dispatch a real `paste` event carrying `text` as `text/plain` only — what a
// copy out of a terminal or a plain-text editor puts on the clipboard.
// Playwright can't write the system clipboard portably, and ProseMirror reads
// `event.clipboardData`, so this is the same code path a keyboard paste takes.
async function pastePlain(locator, text) {
  await locator.evaluate((el, value) => {
    const data = new DataTransfer();
    data.setData("text/plain", value);
    el.dispatchEvent(
      new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }),
    );
  }, text);
}

test.describe("markdown", () => {
  test.beforeEach(async ({ page, browserName }) => {
    // WebKit's ClipboardEvent constructor ignores `clipboardData`, so the
    // synthetic paste arrives empty there; the import journey below needs no
    // clipboard and would pass, but one skip per describe keeps it simple.
    test.skip(browserName === "webkit", "synthetic clipboardData is Chromium-only");
    await signInAsAdmin(page);
  });

  test("pasted Markdown becomes structure, and can go back to plain text or be undone", async ({
    page,
  }) => {
    const id = await newDraftPage(page);
    try {
      await addBlock(page, "rich_text");
      const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();
      await expect(prose).toBeVisible();
      await prose.click();

      const markdown = "## Steps\n\n- first **step**\n- second\n\n[the docs](https://example.com/docs)";
      await pastePlain(prose, markdown);

      await expect(prose.locator("h2")).toHaveText("Steps");
      await expect(prose.locator("li")).toHaveCount(2);
      await expect(prose.locator("strong")).toHaveText("step");
      await expect(prose.locator('a[href="https://example.com/docs"]')).toHaveText("the docs");

      const notice = page.locator(".rt-paste-notice");
      await expect(notice).toContainText("Pasted as Markdown.");

      // The literal text, exactly as copied — no heading, no list.
      await notice.getByRole("button", { name: "Paste as plain text" }).click();
      await expect(notice).toBeHidden();
      await expect(prose.locator("h2")).toHaveCount(0);
      await expect(prose.locator("li")).toHaveCount(0);
      await expect(prose).toContainText("## Steps");
      await expect(prose).toContainText("- first **step**");

      // Undo takes a conversion back out entirely.
      await prose.press("End");
      await pastePlain(prose, "\n### Undone\n");
      await expect(prose.locator("h3")).toHaveText("Undone");
      await notice.getByRole("button", { name: "Undo" }).click();
      await expect(prose.locator("h3")).toHaveCount(0);
      await expect(prose).toContainText("## Steps");
    } finally {
      await deleteContentById(page, "page", id);
    }
  });

  test("Import Markdown lands the file as blocks and the title it names", async ({ page }) => {
    const id = await newDraftPage(page);
    const title = `Imported guide ${Date.now()}`;
    const file = [
      `# ${title}`,
      "",
      "Intro from the file.",
      "",
      "| Setting | Value |",
      "|---|---|",
      "| depth | 3 |",
      "",
      "![Site map](https://img.example.com/map.png)",
      "",
    ].join("\n");

    try {
      // The button opens the (hidden) file input's native chooser.
      const [chooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        page.getByRole("button", { name: "Import Markdown" }).click(),
      ]);
      await chooser.setFiles({
        name: "guide.md",
        mimeType: "text/markdown",
        buffer: Buffer.from(file),
      });

      const dialog = page.locator("#markdown-import-dialog");
      await expect(dialog).toContainText("Import guide.md");
      await expect(dialog).toContainText(title);
      await dialog.getByRole("button", { name: /^import$/i }).click();
      await expect(dialog).toHaveCount(0);

      await expect(page.locator('input[name$="[title]"]')).toHaveValue(title);
      const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();
      await expect(prose).toContainText("Intro from the file.");
      await expect(prose.locator("table")).toHaveCount(1);
      // The leading H1 became the title, so it is not repeated in the body.
      await expect(prose.locator("h1")).toHaveCount(0);

      await save(page);
      await page.reload();
      await expect(page.locator('input[name$="[title]"]')).toHaveValue(title);
      await expect(page.locator('[phx-hook="RichText"] .ProseMirror').first()).toContainText(
        "Intro from the file.",
      );
    } finally {
      await deleteContentById(page, "page", id);
    }
  });

  test("the Markdown view turns pasted Markdown into blocks on the way back", async ({ page }) => {
    const id = await newDraftPage(page);
    try {
      await page.getByRole("button", { name: "Markdown", exact: true }).click();
      const source = page.locator("#markdown-mode-source");
      await expect(source).toBeVisible();
      await expect(page.locator("#blocks-sortable")).toBeHidden();

      await source.fill("## From Markdown\n\n- one\n- **two**\n\n| A | B |\n|---|---|\n| 1 | 2 |\n");
      // Straight to Blocks, inside the debounce: the blur sends the text first.
      await page.getByRole("button", { name: "Blocks", exact: true }).click();
      await expect(source).toHaveCount(0);

      const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();
      await expect(prose.locator("h2")).toHaveText("From Markdown");
      await expect(prose.locator("li")).toHaveCount(2);
      await expect(prose.locator("strong")).toHaveText("two");
      await expect(prose.locator("table")).toHaveCount(1);

      await save(page);
      await page.reload();
      await expect(page.locator('[phx-hook="RichText"] .ProseMirror').first().locator("h2")).toHaveText(
        "From Markdown",
      );

      // And back out: the saved blocks read as the same Markdown.
      await page.getByRole("button", { name: "Markdown", exact: true }).click();
      await expect(page.locator("#markdown-mode-source")).toHaveValue(/^## From Markdown\n\n- one\n- \*\*two\*\*/);
    } finally {
      await deleteContentById(page, "page", id);
    }
  });

  test("switches back and forth, keeping the edits made on either side", async ({ page }) => {
    const id = await newDraftPage(page);
    const markdownButton = page.getByRole("button", { name: "Markdown", exact: true });
    const blocksButton = page.getByRole("button", { name: "Blocks", exact: true });
    const source = page.locator("#markdown-mode-source");
    const prose = page.locator('[phx-hook="RichText"] .ProseMirror').first();

    try {
      // Blocks → Markdown straight after typing: the switch flushes the block.
      await addBlock(page, "rich_text");
      await prose.click();
      await page.keyboard.type("Typed in a block");
      await markdownButton.click();
      await expect(source).toHaveValue("Typed in a block\n");

      // Markdown → Blocks with an edit.
      await source.fill("Typed in a block\n\n## Added in Markdown\n");
      await blocksButton.click();
      await expect(prose.locator("h2")).toHaveText("Added in Markdown");

      // An edit in the block editor, then Markdown again: it shows both.
      await prose.locator("h2").click();
      await page.keyboard.press("End");
      await page.keyboard.type(" and blocks");
      await markdownButton.click();
      await expect(source).toHaveValue("Typed in a block\n\n## Added in Markdown and blocks\n");

      // And back once more, then persisted.
      await source.fill("Typed in a block\n\n## Added in Markdown and blocks\n\n- a list\n");
      await blocksButton.click();
      await expect(prose.locator("li")).toHaveText("a list");
      await save(page);
      await page.reload();
      await expect(page.locator('[phx-hook="RichText"] .ProseMirror').first().locator("li")).toHaveText(
        "a list",
      );
    } finally {
      await deleteContentById(page, "page", id);
    }
  });
});
