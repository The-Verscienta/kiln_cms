// @ts-check
// Escape closes a dialog even when focus is not inside it (#1046).
//
// This spec exists because the bug is unreachable from an Elixir test: it is
// entirely about where `document.activeElement` happens to be when a key is
// pressed, which only a real browser decides. #1029 backed the fix out for want
// of exactly this coverage.
//
// It runs on WebKit as well as Chromium (see `playwright.config.js`), and the
// first test below is why: Safari does not focus a `<button>` on click, so it
// reaches the bug by *doing the thing a person does* rather than by
// synthesising the focus state. On Chromium the same steps exercise the
// unchanged inside-the-panel path, which is worth holding still too.
const { test, expect, signInAsAdmin, newDraftPage, addBlock } = require("./fixtures");

// Open the image-picker drawer from an image block's own "Choose from library"
// button — a `<.modal>`, so it carries the FocusTrap hook.
//
// Targeted by its event, not its label: a draft page renders three "Choose from
// library" buttons (the block's `open_picker`, the featured image's
// `open_featured_picker` and the social image's), all opening the same drawer —
// so matching on the label would silently test whichever came first in the DOM
// and make the `addBlock` above it pointless.
async function openImagePicker(page) {
  await newDraftPage(page);
  await addBlock(page, "image");

  await page.locator('button[phx-click="open_picker"]').first().click();

  const drawer = page.locator("#image-picker-dialog");
  await expect(drawer).toBeVisible();
  return drawer;
}

// `document.body.focus()` alone does nothing — body is not focusable without a
// tabindex, so activeElement stays wherever it was. Blur first, then poll,
// because a test that merely *believes* focus moved exercises the panel
// listener instead and passes for the wrong reason.
async function focusBody(page) {
  await page.evaluate(() => {
    const active = /** @type {HTMLElement | null} */ (document.activeElement);
    if (active && typeof active.blur === "function") active.blur();
    document.body.focus();
  });

  await expect.poll(() => page.evaluate(() => document.activeElement?.tagName)).toBe("BODY");
}

test.describe("FocusTrap", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("Escape closes the dialog after clicking a button inside it", async ({ page }) => {
    // The motivating case, reached the way a person reaches it. On WebKit the
    // click leaves `document.activeElement` on `<body>`, which before #1046
    // meant the panel's listener never saw the press and Escape was dead. On
    // Chromium the button keeps focus, so this covers the inside-the-panel path
    // instead — both must close.
    const drawer = await openImagePicker(page);

    // A button that does not itself close the drawer.
    const filter = drawer.getByRole("button").filter({ hasNotText: /close/i }).first();
    if (await filter.count()) await filter.click();

    await page.keyboard.press("Escape");

    await expect(drawer).toHaveCount(0);
  });

  test("Escape closes the dialog after focus has moved to <body>", async ({ page }) => {
    // The same state, forced, so the assertion does not depend on which engine
    // decides what a click focuses.
    const drawer = await openImagePicker(page);
    await focusBody(page);

    await page.keyboard.press("Escape");

    await expect(drawer).toHaveCount(0);
  });

  test("a detached trap does not answer for the page that replaced it", async ({ page }) => {
    // `destroyed()` runs on a channel round-trip, so after live navigation a
    // torn-down hook can still be listening while its panel is detached. Left
    // unguarded it pushes a close event at a dead view and swallows the press.
    const drawer = await openImagePicker(page);

    // Detach the panel without tearing the hook down — exactly the window live
    // navigation opens, since `destroyed()` waits on a channel round-trip while
    // the replaced element is already gone. Reproduced directly rather than by
    // racing a real navigation, because the whole point is that the window is
    // timing-dependent.
    await page.evaluate(() => {
      document.getElementById("image-picker-dialog")?.remove();
      document.body.focus();
    });

    await expect(drawer).toHaveCount(0);

    // A stale trap would swallow this press and push a close event at a view
    // that no longer exists.
    const eaten = await page.evaluate(() => {
      const e = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
      document.dispatchEvent(e);
      return e.defaultPrevented;
    });

    expect(eaten).toBe(false);
  });
});
