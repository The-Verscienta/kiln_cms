// @ts-check
//
// Content releases (#1314): create a release, add a draft to it from the
// content list, ship it ("Publish now"), see the draft go live, roll the
// release back, see it come off the site again. Ship and rollback both run in
// `KilnCMS.CMS.Workers.ReleaseWorker` on Oban's `:scheduling` queue and report
// back over PubSub — so this journey needs the e2e server to process jobs
// (config/e2e.exs) and proves the release page updates itself when they land.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  saveDraft,
  deleteContentById,
} = require("./fixtures");

// Accept the next native confirm and hand back its message, so the caller
// asserts on the text AFTER the click. Asserting inside the handler would leave
// the confirm open on a mismatch and hang the click until the test timeout.
function acceptNextDialog(page) {
  return new Promise(resolve => {
    page.once("dialog", dialog => {
      resolve(dialog.message());
      return dialog.accept();
    });
  });
}

test.describe("content releases", () => {
  /** @type {string} */
  let releaseName;
  /** @type {string} */
  let title;
  /** @type {string} */
  let slug;
  /** @type {string | null} */
  let pageId = null;
  /** @type {string | null} */
  let releaseUrl = null;

  test.beforeEach(async ({ page }) => {
    const stamp = Date.now();
    releaseName = `E2E Release ${stamp}`;
    title = `E2E Release Page ${stamp}`;
    slug = `e2e-release-page-${stamp}`;
    pageId = null;
    releaseUrl = null;
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Best-effort cleanup. A shipped release cannot be deleted (its
    // `published_at` is set), only archived — and archiving is one-way, so the
    // journey does it last, here, once the assertions are done. The e2e
    // database is persistent, so leaving an open release behind would also
    // change what every later spec sees in the content list's "Add to
    // release" picker.
    //
    // If the journey died mid-flight the release may still be `:publishing` /
    // `:rolling_back`, where the Archive button is hidden and the worker is
    // still touching the page — so wait for a terminal state (the button
    // appears) before archiving, and archive before deleting the page.
    if (releaseUrl) {
      await page.goto(releaseUrl);
      const archive = page.locator('button[phx-click="archive"]');
      await expect(archive).toBeVisible({ timeout: 30_000 }).catch(() => {});
      if (await archive.count()) {
        const accepted = acceptNextDialog(page);
        await archive.click();
        await accepted;
        await expect(page.locator("#flash-info")).toContainText("Release archived.");
      }
      releaseUrl = null;
    }
    if (pageId) {
      await deleteContentById(page, "page", pageId);
      pageId = null;
    }
  });

  test("create → add content → publish now → live → roll back → off the site", async ({ page }) => {
    // Two worker round-trips (ship, roll back) plus a dozen navigations: take
    // the tripled budget rather than racing the 30 s default.
    test.slow();

    // A draft to ship.
    pageId = await newDraftPage(page);
    await saveDraft(page, { title, slug });
    // Not live yet: the public route has nothing for a draft.
    expect((await page.request.get(`/${slug}`)).status()).toBe(404);

    // Create the release; success lands on its own page, in state Open.
    await page.goto("/editor/releases");
    await page.fill('#new-release-form input[name="release[name]"]', releaseName);
    await page.locator("#new-release-form").getByRole("button", { name: "Create release" }).click();
    await page.waitForURL(/\/editor\/releases\/[0-9a-f-]+$/);
    releaseUrl = new URL(page.url()).pathname;
    const heading = page.locator("h1").filter({ hasText: releaseName });
    await expect(heading).toBeVisible();
    await expect(heading.getByText("Open", { exact: true })).toBeVisible();
    await expect(page.getByText("Nothing in this release")).toBeVisible();

    // Add the draft from the content list's bulk toolbar. The panel only
    // offers open releases, and defaults the go-live action to Publish.
    await page.goto(`/editor?q=${encodeURIComponent(title)}`);
    await page.locator(`li[id="page-${pageId}"] input[type="checkbox"]`).check();
    await page.locator('button[phx-click="open_release_panel"]').click();
    await page.selectOption("#add-to-release-target", { label: releaseName });
    await page.selectOption("#add-to-release-action", "publish");
    await page.locator("#add-to-release button[type=submit]").click();
    await expect(page.locator("#flash-info")).toContainText("Added 1 item(s) to the release");

    // The release now lists it, pending, and can be shipped. `data-confirm`
    // is a native confirm dialog.
    await page.goto(releaseUrl);
    const itemRow = page.locator("tr").filter({ hasText: title });
    await expect(itemRow).toContainText("Pending");
    await expect(itemRow).toContainText("Publish");
    await expect(page.getByText("1 of", { exact: false })).toBeVisible();

    let confirm = acceptNextDialog(page);
    await page.locator('button[phx-click="publish_now"]').click();
    expect(await confirm).toContain("Publish this release now?");
    await expect(page.locator("#flash-info")).toContainText("Publishing the release");
    // The worker finishes off-request and the page follows it over PubSub:
    // the badge flips to Published and the item is Applied without a reload.
    await expect(heading.getByText("Published", { exact: true })).toBeVisible({ timeout: 20_000 });
    await expect(itemRow).toContainText("Applied");

    // …and the page really is live.
    await page.goto(`/${slug}`);
    await expect(page.locator("article h1")).toContainText(title);

    // Roll back: the release and its item say so, and the page is a draft again.
    await page.goto(releaseUrl);
    confirm = acceptNextDialog(page);
    await page.locator('button[phx-click="roll_back"]').click();
    expect(await confirm).toContain("Roll this release back?");
    await expect(page.locator("#flash-info")).toContainText("Rolling the release back");
    await expect(heading.getByText("Rolled back", { exact: true })).toBeVisible({ timeout: 20_000 });
    await expect(itemRow).toContainText("Rolled back");
    await expect(page.locator('button[phx-click="roll_back"]')).toHaveCount(0);

    expect((await page.request.get(`/${slug}`)).status()).toBe(404);
    await page.goto(`/editor?q=${encodeURIComponent(title)}`);
    await expect(page.locator(`li[id="page-${pageId}"]`).getByText("Draft", { exact: true })).toBeVisible();
  });
});
