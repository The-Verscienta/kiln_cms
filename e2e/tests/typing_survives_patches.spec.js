// @ts-check
//
// Typed characters survive a server patch that lands mid-typing (#2133).
//
// The usability round reported the media alt-text field and the Add block
// filter dropping keystrokes ("Orange square" saved as "Orange squ"). The
// filter half was real, in the inline "Insert block here" menus: they render
// inside each block card, the autosave's form rebuild re-renders the cards,
// and its patch put back the server's `hidden` on the open menu. The search
// box lost focus, the patch reset its value, and the rest of the word went to
// <body>. The alt-text half did not reproduce (the field sends nothing while
// typing, and LiveView leaves a focused input's value alone), so its journey
// is a guard: it holds the field across a patch of the drawer around it.
//
// Each journey types, waits until a server patch has actually reached the
// element around the field, finishes typing, and checks every character.
// Checked against a deliberate defect: a patch that replaces the alt field,
// or one that re-hides the inline menu, fails the matching journey.
const fs = require("fs");
const path = require("path");
const { test, expect, signInAsAdmin, newDraftPage, addBlock } = require("./fixtures");

const PNG_PATH = path.join(__dirname, "../../priv/static/images/logo-mark.png");

// Soft-deletes the media item (see media_focal_point.spec.js for the shape).
async function deleteMedia(page, id) {
  await page.goto("/media");
  const card = page.locator(`li[id="media-${id}"]`);
  if ((await card.count()) === 0) return;
  page.once("dialog", dialog => dialog.accept());
  await card.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(card).toHaveCount(0);
}

test.describe("typing across a server patch", () => {
  /** @type {string | null} */
  let mediaId = null;

  test.beforeEach(async ({ page }) => {
    mediaId = null;
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    if (mediaId) await deleteMedia(page, mediaId);
  });

  test("media alt text keeps every character, and saves them", async ({ page }) => {
    test.slow();
    await page.goto("/media");
    const filename = `e2e-alt-${Date.now()}.png`;
    await page.locator("#upload-form input[type=file]").setInputFiles({
      name: filename,
      mimeType: "image/png",
      buffer: fs.readFileSync(PNG_PATH),
    });
    await page.getByRole("button", { name: /^upload 1 file$/i }).click();
    await expect(page.locator("#flash-info")).toContainText("Uploaded 1 file.");
    const card = page.locator("#media-grid li").filter({ hasText: filename }).first();
    mediaId = (await card.getAttribute("id"))?.replace(/^media-/, "") ?? null;
    await card.getByRole("button", { name: `View details for ${filename}` }).click();

    const alt = page.locator("#media-alt");
    await alt.click();
    await page.keyboard.type("Orange squ", { delay: 50 });

    // A server patch over the drawer while the field has focus: the library's
    // own "Regenerate variants" (admin) re-runs the variant worker, whose
    // broadcast re-reads the open item and re-renders the drawer around the
    // field. Wait until that re-render has reached the drawer's DOM, or the
    // rest of the word would be typed before any patch arrived.
    await page.evaluate(() => {
      // @ts-ignore — test-only marker
      window.__drawerPatched = false;
      new MutationObserver(() => {
        // @ts-ignore
        window.__drawerPatched = true;
      }).observe(document.getElementById("media-detail-dialog"), {
        childList: true,
        subtree: true,
        attributes: true,
      });
      const main = document.querySelector("[data-phx-main]");
      // @ts-ignore — liveSocket is app.js's global
      window.liveSocket.execJS(main, JSON.stringify([["push", { event: "regenerate_variants" }]]));
    });
    // @ts-ignore
    await page.waitForFunction(() => window.__drawerPatched, null, { timeout: 20_000 });

    await page.keyboard.type("are", { delay: 50 });
    await expect(alt).toBeFocused();
    await expect(alt).toHaveValue("Orange square");

    await page.getByRole("button", { name: "Save details" }).click();
    await page.goto(`/media?id=${mediaId}`);
    await expect(page.locator("#media-alt")).toHaveValue("Orange square");
  });

  // The inline "Insert block here" menu, not the main Add block one: the
  // inline copy renders inside each block card, which the autosave's form
  // rebuild re-renders, so its patch passes over the filter while it has
  // focus. The main menu sits outside the block list and an autosave never
  // reaches it.
  test("the Add block filter keeps every character through an autosave", async ({ page }) => {
    await newDraftPage(page);
    await addBlock(page, "heading");
    // A dirty block queues an autosave, which lands while the menu is open.
    const heading = page.locator("#block-0").locator("textarea, input[type=text]").first();
    await heading.fill(`Typing ${Date.now()}`);
    const status = page.locator("#save-status");
    const before = await status.getAttribute("data-at");

    const inserter = page.locator('[id^="insert-after-"]').first();
    await inserter.locator("[data-inserter-trigger]").click();
    const search = inserter.locator("[data-inserter-search]");
    await expect(search).toBeFocused();
    await page.keyboard.type("rich", { delay: 50 });

    // The autosave's patch has been applied once the stamp moves.
    await expect(status).not.toHaveAttribute("data-at", before || "", { timeout: 10_000 });

    await page.keyboard.type(" text", { delay: 50 });
    await expect(search).toBeFocused();
    await expect(search).toHaveValue("rich text");
    await expect(
      inserter.locator('button[data-inserter-item][phx-value-type="rich_text"]:visible'),
    ).toHaveCount(1);
  });
});
