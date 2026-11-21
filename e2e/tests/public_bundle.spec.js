// @ts-check
//
// Signed-out content pages load `public.js`, not app.js (#2402). The
// ConnCase test (test/kiln_cms_web/js_bundle_test.exs) checks which <script>
// each page names; only a browser shows what it actually fetched, that the
// small bundle runs without an error, and that a page which kept app.js for
// its flash still closes that flash.
const {
  test,
  expect,
  signInAsAdmin,
  waitForLiveConnected,
  newGuardedContext,
} = require("./fixtures");

// Every script the page requests, by path, and every error it reports.
function record(page) {
  const scripts = [];
  const errors = [];
  page.on("request", (request) => {
    if (request.resourceType() === "script") scripts.push(new URL(request.url()).pathname);
  });
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(error.message));
  return { scripts, errors };
}

const bundles = (scripts) => scripts.filter((path) => path.startsWith("/assets/js/"));

test("the blog index loads public.js alone, with no error", async ({ page }) => {
  const seen = record(page);

  const response = await page.goto("/blog");
  expect(response?.status()).toBe(200);
  await page.waitForLoadState("networkidle");

  expect(bundles(seen.scripts)).toEqual([
    expect.stringMatching(/^\/assets\/js\/public(-[0-9a-f]+)?\.js$/),
  ]);
  expect(seen.errors).toEqual([]);
  // No LiveView on the page, so nothing for it to have connected.
  expect(await page.evaluate(() => "liveSocket" in window)).toBe(false);
});

test("a form's own page loads public.js alone, with no error", async ({ page, browser }) => {
  await signInAsAdmin(page);

  await page.goto("/editor/forms");
  await waitForLiveConnected(page);
  const slug = `e2e-bundle-${Date.now()}`;
  await page.fill("#form-name", "E2E public bundle");
  await page.fill('input[name="form[slug]"]', slug);
  await page.locator('form[phx-submit="create_form"] button[type="submit"]').click();
  await expect(page).toHaveURL(/\/editor\/forms\/[0-9a-f-]{36}$/);

  // A fresh context: what a signed-out visitor fetches.
  const { context: visitor, page: reader } = await newGuardedContext(browser);
  const seen = record(reader);

  const response = await reader.goto(`/forms/${slug}`);
  expect(response?.status()).toBe(200);
  await reader.waitForLoadState("networkidle");

  expect(bundles(seen.scripts)).toEqual([
    expect.stringMatching(/^\/assets\/js\/public(-[0-9a-f]+)?\.js$/),
  ]);
  expect(seen.errors).toEqual([]);
  await visitor.close();
});

test("sign-out lands on / with app.js, and its flash still closes", async ({ page }) => {
  await signInAsAdmin(page);

  // `/sign-out` is a LiveView that asks first; its button signs out.
  await page.goto("/sign-out");
  await waitForLiveConnected(page);
  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page).toHaveURL("/");
  const flash = page.locator("#flash-info");
  await expect(flash).toContainText("You are now signed out");
  // The flash is spent on this render, so read what this page loaded off the
  // page itself rather than reloading it: its one bundle, and that it ran.
  const src = await page.evaluate(
    () => document.querySelector('script[src^="/assets/js/"]')?.getAttribute("src") || "",
  );
  expect(src).toMatch(/^\/assets\/js\/app(-[0-9a-f]+)?\.js/);
  expect(await page.evaluate(() => "liveSocket" in window)).toBe(true);

  await flash.click();
  await expect(flash).toBeHidden();
});
