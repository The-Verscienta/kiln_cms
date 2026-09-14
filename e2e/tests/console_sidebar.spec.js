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

  // Collapsible Configure sections (#1319). Same reasoning as the rail: the
  // state lives on <html data-nav-collapsed> and in localStorage, the server
  // always renders the section expanded, and CSS does the hiding — so the only
  // place the feature is real is a browser.
  test("sections collapse, survive navigation and reload, and yield to the rail", async ({
    page,
  }) => {
    const html = page.locator("html");
    const head = sidebar(page).getByRole("button", { name: "Delivery" });
    const branding = sidebar(page).getByRole("link", { name: "Branding", exact: true });

    await expect(head).toHaveAttribute("aria-expanded", "true");
    await expect(branding).toBeVisible();

    await head.click();
    await expect(html).toHaveAttribute("data-nav-collapsed", /\bdelivery\b/);
    await expect(head).toHaveAttribute("aria-expanded", "false");
    await expect(branding).toBeHidden();

    // A live navigation re-renders the sidebar from a server that thinks every
    // section is open; the client's state outlives the patch either way.
    await sidebar(page).getByRole("link", { name: "Media", exact: true }).click();
    await expect(page).toHaveURL("/media");
    await expect(branding).toBeHidden();
    await expect(head).toHaveAttribute("aria-expanded", "false");

    // Restored before first paint, like the rail.
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(html).toHaveAttribute("data-nav-collapsed", /\bdelivery\b/);

    // The rail has no room to explain a missing section, so collapse is
    // ignored there and the head stops taking clicks.
    await page.getByRole("button", { name: "Collapse sidebar" }).click();
    await expect(branding).toBeVisible();
    await page.getByRole("button", { name: "Expand sidebar" }).click();
    await expect(branding).toBeHidden();

    await head.click();
    await expect(html).not.toHaveAttribute("data-nav-collapsed", /\bdelivery\b/);
    await expect(branding).toBeVisible();
  });

  // The operator band (#1319): the instance-wide screens, ruled off from the
  // day-to-day admin above them.
  test("the operator screens are set apart from day-to-day admin", async ({ page }) => {
    const ops = sidebar(page).locator('.side-group-op[data-nav-group="operations"]');

    await expect(ops.getByRole("button", { name: "Operations" })).toBeVisible();
    await expect(ops.getByRole("link", { name: "Backups", exact: true })).toBeVisible();
    await expect(ops.getByRole("link", { name: "System", exact: true })).toBeVisible();
    await expect(
      sidebar(page).locator('.side-group-op[data-nav-group="delivery"]'),
    ).toHaveCount(0);

    // A rule above the band, not just a heading: the separation has to read at
    // a glance, which a sixth identical group head does not.
    await expect
      .poll(() => ops.evaluate(el => getComputedStyle(el).borderTopWidth))
      .toBe("1px");
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
