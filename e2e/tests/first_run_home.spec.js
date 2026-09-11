// @ts-check
//
// First-run path (usability review, B4): a published page with the slug
// `home` takes over the site root, and every console page links to the public
// site. The Overview's "Get your site live" checklist is covered by the
// LiveView tests instead — it only shows while NOTHING is published, and this
// suite's seeds publish demo content.
//
// Cleanup frees the `home` slug rather than only deleting the page: delete is
// a soft delete (archival), so a trashed row could otherwise hold the slug
// against the next run. Unpublishing first keeps the rename from standing a
// redirect up under `/home`.
//
// Set E2E_SHOTS=<dir> to save a screenshot at each step.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  saveDraft,
  deleteContentById,
} = require("./fixtures");

const TITLE = "Hours and location";

async function shot(page, name) {
  if (process.env.E2E_SHOTS) {
    await page.screenshot({ path: `${process.env.E2E_SHOTS}/${name}.png` });
  }
}

const workflowButton = (page, action) =>
  page.locator(`button[phx-click="workflow"][phx-value-action="${action}"]`);

test("a published Home page takes over the site root", async ({ page }) => {
  await signInAsAdmin(page);
  await shot(page, "1-overview");

  // Every console page links to the public site.
  await expect(page.locator("#console-view-site")).toHaveAttribute("href", "/");

  // No Home page yet: the root is the stock template.
  await page.goto("/");
  await expect(page.getByText("Model content once")).toBeVisible();

  let id;
  try {
    id = await newDraftPage(page);
    await saveDraft(page, { title: TITLE, slug: "home" });

    // A draft Home page must not reach visitors.
    await page.goto("/");
    await expect(page.getByText("Model content once")).toBeVisible();

    await page.goto(`/editor/content/page/${id}`);
    await workflowButton(page, "publish").click();
    await expect(workflowButton(page, "unpublish")).toBeVisible();
    await shot(page, "2-editor-published");

    await page.goto("/");
    await expect(page.locator("article h1")).toContainText(TITLE);
    await expect(page.getByText("Model content once")).toHaveCount(0);
    await shot(page, "3-site-root");
  } finally {
    if (id) {
      await page.goto(`/editor/content/page/${id}`);
      if (await workflowButton(page, "unpublish").count()) {
        await workflowButton(page, "unpublish").click();
        await expect(workflowButton(page, "publish")).toBeVisible();
      }
      await saveDraft(page, { title: TITLE, slug: `e2e-home-${Date.now()}` });
      await deleteContentById(page, "page", id);
    }
  }
});
