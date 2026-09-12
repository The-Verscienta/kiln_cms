// @ts-check
// The console sidebar (Layouts.console/1): the icon-rail collapse, its
// tooltips, the segmented theme switch and the account menu.
//
// Browser-only on purpose: the rail state lives on <html data-sidebar> and in
// localStorage, both outside anything a LiveView test renders, and the claims
// that matter — it survives a live navigation, it is restored before first
// paint, a hidden label still names its link — are about what a real browser
// does with that markup.
const { test, expect, signInAsAdmin } = require("./fixtures");

const sidebar = page => page.locator("aside.side-shell");

test.describe("console sidebar", () => {
  // The rail is an lg+ affordance; below that the sidebar is a drawer.
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test("collapses to an icon rail that survives navigation and reload", async ({ page }) => {
    const html = page.locator("html");
    const media = sidebar(page).getByRole("link", { name: "Media", exact: true });

    await page.getByRole("button", { name: "Collapse sidebar" }).click();
    await expect(html).toHaveAttribute("data-sidebar", "collapsed");
    await expect.poll(async () => (await sidebar(page).boundingBox())?.width).toBeLessThan(80);

    // The label is visually hidden, not removed: the link keeps its name.
    await expect(media).toBeVisible();

    // The rail names the icon under the pointer.
    await media.hover();
    await expect(page.locator(".side-tip")).toHaveText("Media");

    // A live navigation re-renders the layout but never touches <html>.
    await media.click();
    await expect(page).toHaveURL("/media");
    await expect(html).toHaveAttribute("data-sidebar", "collapsed");

    // The pointer is still on Media, so its tooltip is (rightly) back; leaving
    // the rail takes it away.
    await page.locator("main").hover();
    await expect(page.locator(".side-tip")).toHaveCount(0);

    // A full load restores the rail from localStorage before first paint:
    // the attribute is already there at DOMContentLoaded, before app.js runs.
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(html).toHaveAttribute("data-sidebar", "collapsed");

    await page.getByRole("button", { name: "Expand sidebar" }).click();
    await expect(html).not.toHaveAttribute("data-sidebar", /.*/);
    await expect.poll(async () => (await sidebar(page).boundingBox())?.width).toBeGreaterThan(200);
    await media.hover();
    await expect(page.locator(".side-tip")).toHaveCount(0);
  });

  // #1319. The closed set lives in localStorage and is applied as a <style> in
  // <head>, for the same reason the rail lives on <html>: LiveView patches the
  // nav markup, so state kept ON those elements does not survive a navigation.
  // Only a real browser can show that it does.
  test("Configure sections collapse, and stay collapsed across navigation and reload", async ({
    page,
  }) => {
    const head = sidebar(page).getByRole("button", { name: "Content model" });
    const types = sidebar(page).getByRole("link", { name: "Content types", exact: true });
    const branding = sidebar(page).getByRole("link", { name: "Branding", exact: true });

    await expect(head).toHaveAttribute("aria-expanded", "true");
    await expect(types).toBeVisible();

    await head.click();
    await expect(head).toHaveAttribute("aria-expanded", "false");
    await expect(types).toBeHidden();
    // Only that group: the others are untouched.
    await expect(branding).toBeVisible();

    // A live navigation re-renders the whole nav from the server, which draws
    // every group expanded — the rule in <head> is what keeps this one closed.
    await branding.click();
    await expect(page).toHaveURL("/editor/branding");
    await expect(types).toBeHidden();
    await expect(head).toHaveAttribute("aria-expanded", "false");

    // A full load restores it before first paint, like the rail.
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(types).toBeHidden();

    await head.click();
    await expect(types).toBeVisible();
    await expect(head).toHaveAttribute("aria-expanded", "true");
  });

  // A group closed at full width must not strand its links on the rail, where
  // there is no heading left to click.
  test("the icon rail re-opens every collapsed section", async ({ page }) => {
    const head = sidebar(page).getByRole("button", { name: "Content model" });
    const types = sidebar(page).getByRole("link", { name: "Content types", exact: true });

    await head.click();
    await expect(types).toBeHidden();

    await page.getByRole("button", { name: "Collapse sidebar" }).click();
    await expect(types).toBeVisible();

    await page.getByRole("button", { name: "Expand sidebar" }).click();
    await expect(types).toBeHidden();
  });

  test("the theme switch sets the theme from the sidebar", async ({ page }) => {
    const html = page.locator("html");

    await sidebar(page).getByRole("button", { name: "Use dark theme" }).click();
    await expect(html).toHaveAttribute("data-theme", "dark");
    await expect(html).toHaveAttribute("data-theme-source", "user");

    await sidebar(page).getByRole("button", { name: "Use light theme" }).click();
    await expect(html).toHaveAttribute("data-theme", "light");

    await sidebar(page).getByRole("button", { name: "Use system theme" }).click();
    await expect(html).toHaveAttribute("data-theme-source", "system");
  });

  test("the account menu opens, and closes on Escape and outside clicks", async ({ page }) => {
    const account = page.locator("#side-account");
    const signOut = account.getByRole("link", { name: "Sign out" });

    await account.locator("summary").click();
    await expect(signOut).toBeVisible();
    await expect(account.getByRole("link", { name: "Account" })).toBeVisible();

    await page.keyboard.press("Escape");
    await expect(signOut).toBeHidden();

    await account.locator("summary").click();
    await expect(signOut).toBeVisible();
    await page.locator("main").click({ position: { x: 10, y: 10 } });
    await expect(signOut).toBeHidden();
  });
});
