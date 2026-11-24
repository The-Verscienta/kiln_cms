// @ts-check
//
// The root layout's inline theme script, and app.js, with Web Storage blocked
// (#2773), and the theme on the public form's own answers (#2715).
//
// Browser-only: the theme is set by an inline script before first paint and
// lives on <html data-theme>, and "storage blocked" is a browser setting. No
// server test runs either script.
//
// Blocked storage is what Chrome does with site data blocked: the
// `localStorage` / `sessionStorage` getters themselves throw a SecurityError.
// An unguarded read there used to stop the theme script before it set a theme
// or installed its listeners, and LiveSocket's constructor (which reads both
// stores) stopped the whole of app.js.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

function blockStorage() {
  for (const name of ["localStorage", "sessionStorage"]) {
    Object.defineProperty(window, name, {
      configurable: true,
      get() {
        throw new DOMException("The operation is insecure.", "SecurityError");
      },
    });
  }
}

// Uncaught errors the page reports.
function pageErrors(page) {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  return errors;
}

test.describe("with storage blocked (#2773)", () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(blockStorage);
  });

  test.describe("a public page", () => {
    test.use({ colorScheme: "dark" });

    test("still takes the system theme and follows it", async ({ page }) => {
      const errors = pageErrors(page);
      const html = page.locator("html");

      await page.goto("/blog");
      await expect(html).toHaveAttribute("data-theme", "dark");
      await expect(html).toHaveAttribute("data-theme-source", "system");

      // The prefers-color-scheme listener was installed after the storage reads.
      await page.emulateMedia({ colorScheme: "light" });
      await expect(html).toHaveAttribute("data-theme", "light");

      expect(errors).toEqual([]);
    });
  });

  test.describe("the console", () => {
    // The rail is an lg+ affordance; below that the sidebar is a drawer.
    test.use({ viewport: { width: 1280, height: 800 } });

    test("connects, and its theme switch and sidebar toggle still work", async ({ page }) => {
      const errors = pageErrors(page);
      const html = page.locator("html");
      const sidebar = page.locator("aside.side-shell");

      // signInAs waits for the LiveView to join: app.js ran and connected.
      await signInAsAdmin(page);
      expect(await page.evaluate(() => window.liveSocket.isConnected())).toBe(true);

      await sidebar.getByRole("button", { name: "Use dark theme" }).click();
      await expect(html).toHaveAttribute("data-theme", "dark");
      await expect(html).toHaveAttribute("data-theme-source", "user");
      await sidebar.getByRole("button", { name: "Use light theme" }).click();
      await expect(html).toHaveAttribute("data-theme", "light");

      // The click listener writes the rail state and then hands focus to the
      // twin toggle; with storage blocked the write must not stop it.
      await page.getByRole("button", { name: "Collapse sidebar" }).click();
      await expect(html).toHaveAttribute("data-sidebar", "collapsed");
      await expect(page.locator(".side-expand")).toBeFocused();
      await page.getByRole("button", { name: "Expand sidebar" }).click();
      await expect(html).not.toHaveAttribute("data-sidebar", /.*/);

      expect(errors).toEqual([]);
    });
  });
});

// #2715: the on-site answers to a form submission render the site's layout
// under the `:public_form` pipeline's policy, which carried no nonce, so the
// theme script never ran there and the page was light whatever the visitor's
// theme.
test.describe("a form's refused submission (#2715)", () => {
  test.use({ colorScheme: "dark" });

  test("renders in the visitor's theme", async ({ page }) => {
    await signInAsAdmin(page);

    await page.goto("/editor/forms");
    await waitForLiveConnected(page);
    const slug = `e2e-theme-${Date.now()}`;
    await page.fill("#form-name", "E2E theme on answers");
    await page.fill('input[name="form[slug]"]', slug);
    await page.locator('form[phx-submit="create_form"] button[type="submit"]').click();
    await expect(page).toHaveURL(/\/editor\/forms\/[0-9a-f-]{36}$/);
    await waitForLiveConnected(page);

    await page.locator('button[phx-click="add_field"][phx-value-type="string"]').click();
    await expect(page.locator("#fs-name")).toHaveValue("string");
    await page.locator('input[type="checkbox"][name="field[required]"]').check();
    await expect(page.locator("#field-settings-status")).toContainText("Saved.");

    await page.goto(`/forms/${slug}`);
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");

    // Whitespace satisfies the browser's `required`; the server trims it and
    // refuses the field: a 422 re-render from POST /forms/:slug.
    const prefix = `kiln-form-${slug}`;
    await page.fill(`#${prefix}-string`, "   ");
    const [response] = await Promise.all([
      page.waitForResponse(
        (r) => r.request().method() === "POST" && r.url().endsWith(`/forms/${slug}`),
      ),
      page.locator("form.kiln-form button[type=submit]").click(),
    ]);
    expect(response.status()).toBe(422);
    await expect(page.locator(`#${prefix}-error-summary`)).toBeVisible();

    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    await expect(page.locator("html")).toHaveAttribute("data-theme-source", "system");
  });
});
