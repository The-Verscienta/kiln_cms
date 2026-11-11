// @ts-check
// Screenshots for docs/editorial-workflow.md (#2158): one draft taken from an
// editor's first save to an admin's approval and a live edit. Not a test — see
// ../screenshots.config.js. Run it on its own:
//
//     cd e2e && npm ci
//     npx playwright test -c screenshots.config.js editorial-workflow
//     scripts/optimize_home_images.sh docs   # derive docs/images/editorial-workflow/
//
// Raw captures go to e2e/screenshots/raw/workflow-*.jpg (gitignored). Only the
// WebP files the script derives are committed.
//
// It runs against the e2e seeds as they are: the seeded editor may not publish
// (Team → Publishing is off), which is the workflow the guide walks through.
// It checks that before taking a picture, and fails rather than photograph a
// site configured some other way.
const fs = require("fs");
const path = require("path");
const {
  test,
  expect,
  newGuardedContext,
  signInAsAdmin,
  signInAsEditor,
  newDraftPage,
  saveDraft,
  save,
  addBlock,
  deleteContentByTitle,
  deleteContentById,
} = require("../tests/fixtures");
const { annotate } = require("./annotate");

const OUT = path.resolve(__dirname, "raw");
const TITLE = "Spring firing schedule";
const SLUG = "spring-firing-schedule";
const BODY =
  "The spring firings run every other Saturday from March. Book a shelf by the Wednesday before.";

// A "Saved." toast sits over the top-right of the frame; it is click-to-dismiss.
/** @param {import("@playwright/test").Page} page */
async function settled(page) {
  const flash = page.locator("#flash-info");
  if (await flash.isVisible()) {
    await flash.click();
    await expect(flash).toBeHidden();
  }
  await page.waitForLoadState("networkidle");
  await page.evaluate(() => document.fonts.ready);
}

/**
 * @param {import("@playwright/test").Page} page
 * @param {string} name
 * @param {{ locator: import("@playwright/test").Locator, n: number }[]} markers
 * @param {{ x: number, y: number, width: number, height: number }} [clip]
 */
async function shoot(page, name, markers, clip = undefined) {
  fs.mkdirSync(OUT, { recursive: true });
  await settled(page);
  await annotate(page, markers, { path: path.join(OUT, `workflow-${name}.jpg`), clip });
}

// Deleting moves a page to the trash, where it still holds its slug; the next
// run's draft could not take it. So the run's own page is purged as well.
/** @param {import("@playwright/test").Page} page */
async function removeDraft(page) {
  await deleteContentByTitle(page, TITLE);
  await page.goto("/editor/trash");
  const rows = page.locator('li[id^="trash-page-"]').filter({ hasText: `/${SLUG}` });
  for (let n = await rows.count(); n > 0; n--) {
    page.once("dialog", dialog => dialog.accept());
    await rows.first().getByRole("button", { name: "Delete permanently" }).click();
    await expect(rows).toHaveCount(n - 1);
  }
}

/** @param {import("@playwright/test").Page} page @param {string} action */
const workflowButton = (page, action) =>
  page.locator(`#editor-action-bar button[phx-click="workflow"][phx-value-action="${action}"]`);

/** @param {import("@playwright/test").Page} page */
const statePill = page => page.locator("#editor-action-bar span.rounded-full").first();

test("capture the editorial workflow guide", async ({ page, browser }) => {
  const admin = await newGuardedContext(browser);
  /** @type {string | undefined} */
  let id;

  try {
    await signInAsAdmin(admin.page);
    // A run that failed before its cleanup leaves the draft behind.
    await removeDraft(admin.page);

    // ── The editor writes a draft ────────────────────────────────────────
    await signInAsEditor(page);
    id = await newDraftPage(page);
    const editorUrl = page.url();
    await saveDraft(page, { title: TITLE, slug: SLUG });
    await addBlock(page, "rich_text");
    const body = page.locator('[phx-hook="RichText"] [data-editor]').first();
    await expect(body).toBeVisible();
    await body.click();
    await page.keyboard.type(BODY);
    await expect(page.locator("article:visible")).toContainText(BODY);
    await save(page);

    // The starting state the guide describes: editors submit, admins publish.
    await expect(workflowButton(page, "submit")).toBeVisible();
    await expect(workflowButton(page, "publish")).toHaveCount(0);
    await expect(statePill(page)).toHaveText("Draft");

    // A preview link for someone without an account.
    await page.locator("#share-preview-button").click();
    await expect(page.locator("#share-preview-link")).toBeVisible();

    await shoot(page, "2-draft", [
      { locator: statePill(page), n: 1 },
      { locator: page.locator("#share-preview-button"), n: 2 },
      { locator: workflowButton(page, "submit"), n: 3 },
    ]);

    // The content list: the built-in views, and the row's own verb.
    await page.goto("/editor");
    const row = page.locator(`li[id="page-${id}"]`);
    await expect(row).toBeVisible();
    await shoot(page, "1-content-list", [
      { locator: page.locator("#view-my-drafts"), n: 1 },
      { locator: page.locator("#view-needs-review"), n: 2 },
      { locator: row.locator('button[phx-click="submit"]'), n: 3 },
    ]);

    // ── Preview together ─────────────────────────────────────────────────
    const previewUrl = `/editor/preview/page/${id}`;
    await page.goto(previewUrl);
    await admin.page.goto(previewUrl);
    const viewing = page.getByText("2 viewing", { exact: true });
    await expect(viewing).toBeVisible();
    await expect(page.locator("main, article").first()).toContainText(BODY);
    // The page is one short paragraph: the frame stops below it.
    await shoot(page, "3-preview", [{ locator: page.getByLabel("People viewing"), n: 1 }], {
      x: 0,
      y: 0,
      width: 1440,
      height: 340,
    });

    // ── Submit for review ────────────────────────────────────────────────
    await page.goto(editorUrl);
    await workflowButton(page, "submit").click();
    const awaiting = page.locator("#editor-action-bar").getByText("Awaiting admin approval");
    await expect(awaiting).toBeVisible();
    // The rail comes back on the tab last used (Settings, from the slug):
    // show the page instead.
    const previewTab = page.locator('button[role="tab"][phx-value-tab="preview"]');
    await previewTab.click();
    await expect(previewTab).toHaveAttribute("aria-selected", "true");
    await expect(statePill(page)).toHaveText("In review");
    await shoot(page, "4-submitted", [
      { locator: statePill(page), n: 1 },
      { locator: awaiting, n: 2 },
    ]);

    // ── The admin reviews ────────────────────────────────────────────────
    await admin.page.goto("/editor?status=in_review");
    const queued = admin.page.locator(`li[id="page-${id}"]`);
    await expect(queued).toBeVisible();
    await expect(admin.page.locator("#view-needs-review")).toHaveAttribute("aria-current", "page");
    await shoot(admin.page, "5-needs-review", [
      { locator: admin.page.locator("#view-needs-review"), n: 1 },
      { locator: queued.locator('button[phx-click="publish"]'), n: 2 },
    ]);

    await admin.page.goto(editorUrl);
    await expect(workflowButton(admin.page, "publish")).toHaveText("Approve & publish");
    await shoot(admin.page, "6-review", [
      { locator: workflowButton(admin.page, "publish"), n: 1 },
      { locator: workflowButton(admin.page, "return"), n: 2 },
    ]);

    await workflowButton(admin.page, "publish").click();
    await expect(workflowButton(admin.page, "unpublish")).toBeVisible();

    // ── The editor changes the live page ─────────────────────────────────
    await page.goto(editorUrl);
    await expect(statePill(page)).toHaveText("Published");
    await page.locator('[phx-hook="RichText"] [data-editor] .ProseMirror').first().click();
    await page.keyboard.press("End");
    await page.keyboard.type(" The kiln opens at nine.");
    await save(page);
    await expect(statePill(page)).toHaveText("Live · draft");
    const publishChanges = page.locator("#publish-changes");
    await expect(publishChanges).toBeVisible();
    await shoot(page, "7-live-draft", [
      { locator: statePill(page), n: 1 },
      { locator: publishChanges, n: 2 },
    ]);

    // ── Who may publish ──────────────────────────────────────────────────
    await admin.page.goto("/editor/team");
    const toggle = admin.page.locator("#team-toggle-publishing");
    await expect(toggle).toHaveText("Let editors publish");
    await shoot(admin.page, "8-team-publishing", [{ locator: toggle, n: 1 }]);
  } finally {
    // By id as well: a run that failed before the title landed left an
    // "Untitled page" that no title search finds.
    if (id) await deleteContentById(admin.page, "page", id);
    await removeDraft(admin.page);
    await admin.context.close();
  }
});
