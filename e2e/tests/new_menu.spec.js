// @ts-check
//
// The content list's collapsed "New" menu (#2145). Past three content types,
// /editor folds its "New …" buttons into a disclosure: a <button
// aria-expanded aria-controls> that shows and hides the panel. app.js's shared
// `data-autoclose` handler closes it on Escape or a click outside, and claims
// Escape only while the menu is open. A LiveView test can't run app.js, so the
// keyboard and focus contract is pinned here.
//
// The demo seeds define only page and post, so the spec defines two types of
// its own to cross the threshold, and archives them again afterwards.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

test.describe("content list New menu", () => {
  /** @type {string[]} */
  let names;

  test.beforeEach(async ({ page }) => {
    const stamp = String(Date.now());
    names = [`e2e_menu_a_${stamp}`, `e2e_menu_b_${stamp}`];
    await signInAsAdmin(page);

    for (const name of names) {
      await page.goto("/editor/types");
      await page.fill('#new-type-form input[name="type_definition[label]"]', `Menu ${name}`);
      await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `Menu ${name}s`);
      await page.fill('#new-type-form input[name="type_definition[name]"]', name);
      await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
      await expect(page.locator("#flash-info")).toContainText("Content type created.");
    }
  });

  test.afterEach(async ({ page }) => {
    // Archive both types so later specs see the seeds' inline buttons again.
    for (const name of names) {
      await page.goto("/editor/types");
      const type = page.locator("li[id^='type-']").filter({ hasText: name });
      if (await type.count()) {
        page.once("dialog", dialog => dialog.accept());
        await type.getByRole("button", { name: "Archive content type" }).click();
        await expect(type).toHaveCount(0);
      }
    }
  });

  test("is a button that opens, closes on Escape and outside clicks, and leaves other Escapes alone", async ({
    page,
  }) => {
    await page.goto("/editor");
    await waitForLiveConnected(page);

    const toggle = page.locator("#content-new-menu-toggle");
    const panel = page.locator("#content-new-menu-list");

    // A native button, collapsed, naming the panel it controls.
    await expect(page.getByRole("button", { name: "New", exact: true })).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(toggle).toHaveAttribute("aria-controls", "content-new-menu-list");
    await expect(panel).toBeHidden();

    // Escape while the menu is closed belongs to whatever has focus: the
    // search box keeps it.
    const search = page.locator("#content-search-input");
    await search.focus();
    await page.keyboard.press("Escape");
    await expect(search).toBeFocused();
    await expect(toggle).not.toBeFocused();

    // Keyboard open: Enter on the focused trigger shows the panel.
    await toggle.focus();
    await page.keyboard.press("Enter");
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toBeVisible();
    await expect(panel.locator(`button[phx-value-kind="${names[0]}"]`)).toBeVisible();

    // Tab into the panel, then Escape closes it and hands focus back.
    await page.keyboard.press("Tab");
    await expect(panel.locator("button").first()).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(toggle).toBeFocused();

    // A click outside closes it too.
    await toggle.click();
    await expect(panel).toBeVisible();
    await page.locator("h1").first().click();
    await expect(panel).toBeHidden();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");

    // And an item still opens a new draft of its type.
    await toggle.click();
    await panel.locator(`button[phx-value-kind="${names[0]}"]`).click();
    await page.waitForURL(new RegExp(`/editor/content/${names[0]}/new$`));
  });
});
