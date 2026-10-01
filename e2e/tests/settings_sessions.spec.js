// @ts-check
// Active sessions on Your settings (#1823): signing out the other sessions
// from one browser closes the page another browser has open, over the real
// socket, and that browser is signed out on its next load.
//
// The LiveView tests drive the same effect through LiveViewTest; this is the
// half they cannot reach — the per-session broadcast arriving at a LiveView
// that is connected over an actual WebSocket, and the browser following the
// redirect it sends.
const config = require("../playwright.config");
const { test, expect, EDITOR, waitForLiveConnected } = require("./fixtures");

const FIREFOX_LINUX = "Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0";

async function signIn(page) {
  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: /sign in/i }).click();
  await expect(page).toHaveURL("/editor/overview");
}

test.describe("active sessions", () => {
  test("signing out the other sessions closes the other browser's page", async ({ page, browser }) => {
    // A second, separate browser — its own cookies — reporting itself as
    // Firefox, so the list can tell the two apart.
    const other = await browser.newContext({ baseURL: config.use.baseURL, userAgent: FIREFOX_LINUX });
    const otherPage = await other.newPage();

    try {
      await signIn(page);
      await signIn(otherPage);

      await otherPage.goto("/editor/settings");
      await waitForLiveConnected(otherPage);

      await page.goto("/editor/settings");
      await waitForLiveConnected(page);

      const list = page.locator("#session-list");
      await expect(list.locator("li").first()).toContainText("This session");
      await expect(list).toContainText("Firefox on Linux");

      // "Sign out of all other sessions" asks first.
      page.once("dialog", dialog => dialog.accept());
      await page.locator("#sign-out-other-sessions").click();

      await expect(page.locator("#sessions-only-this")).toBeVisible();
      await expect(list).not.toContainText("Firefox on Linux");

      // The other browser's open page is sent to sign-in without it doing
      // anything, and stays signed out when it tries the console again.
      await expect(otherPage).toHaveURL(/\/sign-in/);
      await otherPage.goto("/editor/settings");
      await expect(otherPage).toHaveURL(/\/sign-in/);

      // This browser is untouched.
      await page.reload();
      await expect(page).toHaveURL("/editor/settings");
      await expect(page.locator("#session-list li").first()).toContainText("This session");
    } finally {
      await other.close();
    }
  });
});
