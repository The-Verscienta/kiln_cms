// @ts-check
// The console's mobile nav drawer (Layouts.console/1) — the one path through
// the sidebar that only exists below 64rem, and the one no other spec covers:
// console_sidebar.spec.js and console_sidebar_layout.spec.js both run at 1280.
//
// The drawer is a CSS checkbox, so none of what follows is visible to a
// LiveView test: whether a reader is told the nav opened, whether Escape and
// Tab behave, and whether the drawer is still lying over the page after it
// takes you somewhere.
const { test, expect, signInAsAdmin } = require("./fixtures");

const aside = page => page.locator("#console-sidebar");
const hamburger = page => page.locator("#kiln-nav-button");
const focusInsideDrawer = page =>
  page.evaluate(() => !!document.activeElement?.closest("#console-sidebar"));

// Off-canvas is `-translate-x-full`, so the whole panel sits left of the
// viewport; open, it starts at or after x=0.
const asideRight = page => aside(page).evaluate(el => el.getBoundingClientRect().right);
const asideLeft = page => aside(page).evaluate(el => el.getBoundingClientRect().left);

test.describe("console mobile drawer", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("opens from the hamburger, says so, and hands focus back on Escape", async ({ page }) => {
    await expect(hamburger(page)).toHaveAttribute("aria-expanded", "false");
    await expect(hamburger(page)).toHaveAttribute("aria-controls", "console-sidebar");
    await expect.poll(() => asideRight(page)).toBeLessThanOrEqual(0);

    await hamburger(page).click();
    await expect(hamburger(page)).toHaveAttribute("aria-expanded", "true");
    await expect.poll(() => asideLeft(page)).toBeGreaterThanOrEqual(0);
    expect(await focusInsideDrawer(page)).toBe(true);

    await page.keyboard.press("Escape");
    await expect(hamburger(page)).toHaveAttribute("aria-expanded", "false");
    await expect.poll(() => asideRight(page)).toBeLessThanOrEqual(0);
    await expect(hamburger(page)).toBeFocused();
  });

  // `role="button"` promises the keyboard; a bare <label> answers to neither
  // Enter nor Space.
  test("opens from the keyboard", async ({ page }) => {
    await hamburger(page).focus();
    await page.keyboard.press("Enter");
    await expect(hamburger(page)).toHaveAttribute("aria-expanded", "true");

    await page.keyboard.press("Escape");
    await hamburger(page).focus();
    await page.keyboard.press(" ");
    await expect(hamburger(page)).toHaveAttribute("aria-expanded", "true");
  });

  test("a nav item navigates and takes the drawer with it", async ({ page }) => {
    await hamburger(page).click();
    await aside(page).getByRole("link", { name: "Media", exact: true }).click();

    await expect(page).toHaveURL("/media");
    await expect(hamburger(page)).toHaveAttribute("aria-expanded", "false");
    await expect.poll(() => asideRight(page)).toBeLessThanOrEqual(0);
  });

  // The drawer covers the page, so Tab must not walk into content behind the
  // scrim — where a keyboard user would be typing into something invisible.
  test("Tab stays inside the open drawer", async ({ page }) => {
    await hamburger(page).click();

    const focusLast = () =>
      page.evaluate(() => {
        const items = Array.from(
          document.querySelectorAll(
            '#console-sidebar a[href], #console-sidebar button:not([disabled]), #console-sidebar summary',
          ),
        ).filter(el => el.offsetParent !== null);
        items[items.length - 1].focus();
      });

    await focusLast();
    await page.keyboard.press("Tab");
    expect(await focusInsideDrawer(page)).toBe(true);

    await page.keyboard.press("Shift+Tab");
    expect(await focusInsideDrawer(page)).toBe(true);
  });

  test("the page behind the drawer does not scroll", async ({ page }) => {
    const bodyOverflow = () =>
      page.evaluate(() => getComputedStyle(document.body).overflowY);

    expect(await bodyOverflow()).not.toBe("hidden");
    await hamburger(page).click();
    expect(await bodyOverflow()).toBe("hidden");

    await page.keyboard.press("Escape");
    expect(await bodyOverflow()).not.toBe("hidden");
  });
});
