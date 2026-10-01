// @ts-check
//
// The console's keyboard shortcut list (#1839). LiveViewTest checks what the
// panel lists; these are the claims only a browser can check, because the
// panel is the browser's own `popover` and "?" is a key handler in app.js:
//
//   * the account menu's "Keyboard shortcuts" item opens it, Escape closes it;
//   * "?" opens it from the page, but typing "?" in a field types a "?";
//   * the shortcuts it lists answer: ⌘K/Ctrl+K goes to search.
const { test, expect, waitForLiveConnected, signInAsEditor } = require("./fixtures");

test.describe("keyboard shortcut list (#1839)", () => {
  test("opens from the account menu and closes on Escape", async ({ page }) => {
    await signInAsEditor(page);
    await page.goto("/editor/overview");
    await waitForLiveConnected(page);

    const panel = page.locator("#keyboard-shortcuts");
    await expect(panel).toBeHidden();

    await page.locator("#side-account summary").click();
    await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
    await expect(panel).toBeVisible();
    await expect(panel).toContainText("Open search");

    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
  });

  test('"?" opens it, but not while typing in a field', async ({ page }) => {
    await signInAsEditor(page);
    await page.goto("/editor/search");
    await waitForLiveConnected(page);

    const panel = page.locator("#keyboard-shortcuts");
    const field = page.locator("#palette-q");
    await field.click();
    await page.keyboard.type("?");
    await expect(panel).toBeHidden();
    await expect(field).toHaveValue(/\?/);

    await field.blur();
    await page.locator("main h1", { hasText: "Search" }).click();
    await page.keyboard.press("?");
    await expect(panel).toBeVisible();
    await expect(page.locator("#keyboard-shortcuts-close")).toBeFocused();
  });

  test("Ctrl+K, as listed, opens search", async ({ page }) => {
    await signInAsEditor(page);
    await page.goto("/editor/overview");
    await waitForLiveConnected(page);

    await page.locator("main").first().click({ position: { x: 5, y: 5 } });
    await page.keyboard.press("Control+k");
    await expect(page).toHaveURL(/\/editor\/search/);
  });
});
