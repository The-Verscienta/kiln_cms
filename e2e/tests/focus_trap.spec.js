// @ts-check
// Escape closes a dialog even when focus is not inside it (#1046).
//
// This spec exists because the bug is unreachable from an Elixir test: it is
// entirely about where `document.activeElement` happens to be when a key is
// pressed, which only a real browser decides. #1029 backed the fix out for want
// of exactly this coverage.
//
// It runs on WebKit as well as Chromium (see `playwright.config.js`), because
// Safari not focusing a `<button>` on click is the motivating case — a Chromium
// run alone would leave the reported symptom untested.
const { test, expect } = require("./fixtures");

const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

async function signInAsAdmin(page) {
  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();
  await expect(page).toHaveURL("/editor/overview");
}

// A draft with one image block, whose "Choose from library" button opens the
// image-picker drawer — a `<.modal>`, so it carries the FocusTrap hook.
async function openImagePicker(page) {
  await page.goto("/editor");
  const newMenu = page.locator("#content-new-menu summary");
  if (await newMenu.count()) await newMenu.click();
  await page.click('button[phx-click="new"][phx-value-kind="page"]');
  await page.waitForURL(/\/editor\/(content\/page|pages)\//);
  await expect(page.locator('form[id$="-editor"]')).toBeVisible();

  await page.getByRole("button", { name: /add block/i }).click();
  await page
    .locator('button[data-inserter-item][phx-value-type="image"]:visible')
    .first()
    .click();

  await page.getByRole("button", { name: /choose from library/i }).first().click();

  const drawer = page.locator("#image-picker-dialog");
  await expect(drawer).toBeVisible();
  return drawer;
}

test.describe("FocusTrap", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("Escape closes the dialog after focus has moved to <body>", async ({ page }) => {
    const drawer = await openImagePicker(page);

    // Reproduce what Safari does on a click, in every browser: put focus on
    // `<body>` while the dialog is open. Before #1046 the panel listener was
    // the only one, so the press never reached any handler.
    await page.evaluate(() => {
      const active = /** @type {HTMLElement | null} */ (document.activeElement);
      if (active && typeof active.blur === "function") active.blur();
      document.body.focus();
    });

    await expect
      .poll(() => page.evaluate(() => document.activeElement?.tagName))
      .toBe("BODY");

    await page.keyboard.press("Escape");

    await expect(drawer).toHaveCount(0);
  });

  test("Escape still closes from inside, and only once", async ({ page }) => {
    // The #693 property this must not regress: the panel's own listener
    // handles a press from inside, and the new document listener stands down.
    const drawer = await openImagePicker(page);

    await drawer.locator("button").first().focus();
    await page.keyboard.press("Escape");

    await expect(drawer).toHaveCount(0);
    // The editor is still there — a double close would have popped whatever
    // was behind the drawer too.
    await expect(page.locator('form[id$="-editor"]')).toBeVisible();
  });

  test("focus is not dragged back into the dialog when it leaves", async ({ page }) => {
    // The decision this pins: #1046 fixes Escape and deliberately does NOT add
    // a `focusout` recapture. A native `<select>` blurs its element while its
    // dropdown is open in some browsers, so a recapture closes the dropdown the
    // person just opened — and `relatedTarget` is `null` for the very case
    // worth handling (focus landing on `<body>`), so the two cannot be told
    // apart. Asserted as an invariant rather than through a real select, since
    // the drawer that has one (the media audience picker) needs seeded media.
    const drawer = await openImagePicker(page);

    const moved = await page.evaluate(() => {
      const panel = document.getElementById("image-picker-dialog");
      if (!panel) return "no panel";

      // A control outside the dialog, focused while the dialog is open — the
      // shape a native dropdown produces when it blurs its own element.
      const outside = document.createElement("input");
      document.body.appendChild(outside);
      outside.focus();
      panel.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));

      return new Promise(resolve =>
        setTimeout(() => {
          const stolen = document.activeElement !== outside;
          outside.remove();
          resolve(stolen ? "stolen" : "kept");
        }, 50),
      );
    });

    expect(moved).toBe("kept");
    await expect(drawer).toBeVisible();
  });
});
