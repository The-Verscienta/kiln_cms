// @ts-check
//
// Block discussions + @mentions (#1314). An admin opens a block's discussion
// in the content editor, types an `@…`, picks the teammate the server
// suggests, and posts. The mention has to do three things a LiveView test
// can't see end-to-end from the browser's side: the server-rendered dropdown
// must appear as the author types (no debounce on the composer), the pick must
// rewrite the textarea through the `MentionAutocomplete` hook, and — after the
// comment commits — the mentioned editor must actually be notified. The last is
// read off the Swoosh mailbox that config/e2e.exs mounts at /dev/mailbox, and
// then confirmed from the editor's own session, which sees the thread on the
// same block.
//
// Handles are normalised display names (`KilnCMS.CMS.Mentions`): both demo
// users are "Demo …", so `@demo` is ambiguous and the unique handle offered
// for editor@kiln.test is `demoeditor`.
const {
  test,
  expect,
  newGuardedContext,
  signInAsAdmin,
  signInAsEditor,
  newDraftPage,
  addBlock,
  deleteContentById,
} = require("./fixtures");

test.describe("block discussions", () => {
  const stamp = Date.now();
  const title = `E2E Mention ${stamp}`;
  /** @type {string | null} */
  let pageId = null;

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    if (pageId) await deleteContentById(page, "page", pageId);
    pageId = null;
  });

  test("open a block thread → @mention a teammate → they are notified and see it", async ({
    page,
    browser,
  }) => {
    await newDraftPage(page);
    pageId = page.url().split("/").pop() ?? null;
    const editorUrl = new URL(page.url()).pathname;
    await page.fill('input[name$="[title]"]', title);
    await page.fill('input[name$="[slug]"]', `e2e-mention-${stamp}`);
    await addBlock(page, "rich_text");
    // Save so the title on the mention email is the real one, not "Untitled".
    await page.getByRole("button", { name: /^save$/i }).click();
    await expect(page.locator('input[name$="[title]"]')).toHaveValue(title);

    // The block's discussion pin: nothing yet.
    const pin = page.locator('button[phx-click="comment_open"]').first();
    await expect(pin).toHaveAttribute("aria-label", "Start a discussion on this block");
    const bid = await pin.getAttribute("phx-value-bid");
    expect(bid).toBeTruthy();
    await pin.click();
    const thread = page.locator(`#thread-${bid}`);
    await expect(thread).toBeVisible();
    await expect(thread).toContainText("No comments on this block yet.");

    // Type an @-prefix: the server suggests the one teammate it matches, with
    // the unique handle. Ambiguous `@demo` is not offered as anyone's handle.
    const composer = page.locator(`#composer-${bid}`);
    await composer.fill("Please give this intro a second read @demoe");
    const listbox = page.getByRole("listbox", { name: "Mention a teammate" });
    await expect(listbox).toBeVisible();
    await expect(listbox.getByRole("option")).toHaveCount(1);
    await expect(listbox).toContainText("Demo Editor");
    await expect(listbox).toContainText("@demoeditor");
    await expect(listbox).not.toContainText("won't notify");

    // Picking rewrites the composer server-side and closes the dropdown; the
    // hook restores focus with the caret at the end.
    await listbox.locator('button[phx-click="mention_pick"][phx-value-handle="demoeditor"]').click();
    await expect(composer).toHaveValue("Please give this intro a second read @demoeditor ");
    await expect(listbox).toHaveCount(0);
    await expect(composer).toBeFocused();

    // Post it. The card renders the body as text and names the author; the pin
    // now counts one comment.
    await thread.locator('button[phx-click="comment_add"]').click();
    const card = thread.locator("p").filter({ hasText: "@demoeditor" });
    await expect(card).toHaveText("Please give this intro a second read @demoeditor");
    await expect(thread).toContainText("Demo Admin");
    await expect(page.locator(`button[phx-click="comment_close"][phx-value-bid="${bid}"]`).first()).toContainText(
      "1 comment",
    );

    // The mention notified editor@kiln.test: the mail worker runs on Oban's
    // :mail queue and delivers into Swoosh's local mailbox. Poll its JSON.
    await expect
      .poll(
        async () => {
          const res = await page.request.get("/dev/mailbox/json");
          if (!res.ok()) return null;
          const { data } = await res.json();
          return (
            data.find(
              mail =>
                mail.subject === `Demo Admin mentioned you on ${title}` &&
                mail.to.some(to => to.includes("editor@kiln.test")),
            ) ?? null
          );
        },
        { timeout: 20_000 },
      )
      .not.toBeNull();

    // And the mentioned editor, in their own session, sees the thread on the
    // same block — the discussion is on the record, not in the author's tab.
    const { context, page: editorPage } = await newGuardedContext(browser);
    try {
      await signInAsEditor(editorPage);
      await editorPage.goto(editorUrl);
      const theirPin = editorPage.locator(`button[phx-click="comment_open"][phx-value-bid="${bid}"]`);
      await expect(theirPin).toContainText("1 comment");
      await theirPin.click();
      await expect(editorPage.locator(`#thread-${bid}`)).toContainText("@demoeditor");
      await expect(editorPage.locator(`#thread-${bid}`)).toContainText("Demo Admin");
    } finally {
      await context.close();
    }
  });
});
