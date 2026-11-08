// @ts-check
//
// Content list export (#2293): the Export disclosure's links and the bulk bar's
// "Export selected" are plain `<a href>` downloads, not LiveView events. The
// controller and LiveView tests cover the rows and columns; this proves the
// *browser* half — that each link, as the page renders it, really starts a
// download with the attachment filename and carries the filtered / selected
// rows. (csp.spec.js had to learn to skip these links because `page.goto` on a
// download aborts; this is the spec that clicks them.)
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  saveDraft,
  deleteContentById,
} = require("./fixtures");
const fs = require("node:fs");

/** @param {import("@playwright/test").Download} download */
async function readDownload(download) {
  const path = await download.path();
  // The CSV leads with a UTF-8 BOM (so spreadsheets read it as UTF-8): drop it.
  return fs.readFileSync(path, "utf8").replace(/^\uFEFF/, "");
}

test.describe("content list export", () => {
  /** @type {string} */
  let prefix;
  /** @type {string[]} */
  let ids = [];

  test.beforeEach(async ({ page }) => {
    prefix = `E2E Export ${Date.now()}`;
    ids = [];
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    for (const id of ids) await deleteContentById(page, "page", id);
    ids = [];
  });

  test("the Export links and Export selected download the filtered and ticked rows", async ({
    page,
  }) => {
    for (const n of [1, 2]) {
      ids.push(await newDraftPage(page));
      await saveDraft(page, {
        title: `${prefix} ${n}`,
        slug: `${prefix.toLowerCase().replace(/\s+/g, "-")}-${n}`,
      });
    }

    await page.goto(`/editor?q=${encodeURIComponent(prefix)}`);
    await expect(page.locator(`li[id^="page-"]`).filter({ hasText: prefix })).toHaveCount(2);

    // Open the disclosure: the server answers with the matching count.
    await page.locator("#content-export-toggle").click();
    await expect(page.locator("#export-summary")).toHaveText("Export 2 matching");

    // CSV: a download, named as an attachment, holding exactly the two rows.
    const [csvDownload] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#export-csv").click(),
    ]);
    expect(csvDownload.suggestedFilename()).toMatch(/^content-.+\.csv$/);
    const csv = await readDownload(csvDownload);
    expect(csv.split("\n")[0]).toMatch(/^id,type,title,slug,status,locale,updated_at/);
    expect(csv).toContain(`${prefix} 1`);
    expect(csv).toContain(`${prefix} 2`);

    // The click is a download, not a navigation: the list is still there.
    await expect(page.locator("#content-export-toggle")).toBeVisible();
    await expect(page).toHaveURL(/\/editor\?/);

    // JSON: same rows, parseable.
    const [jsonDownload] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#export-json").click(),
    ]);
    expect(jsonDownload.suggestedFilename()).toMatch(/^content-.+\.json$/);
    const json = JSON.parse(await readDownload(jsonDownload));
    const titles = JSON.stringify(json);
    expect(titles).toContain(`${prefix} 1`);
    expect(titles).toContain(`${prefix} 2`);

    // Export selected: tick one row only; the download carries just that one.
    await page.locator(`li[id="page-${ids[0]}"] input[type="checkbox"]`).check();
    await expect(page.getByText("1 selected")).toBeVisible();
    const [selected] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#bulk-export-selected").click(),
    ]);
    const selectedCsv = await readDownload(selected);
    expect(selectedCsv).toContain(`${prefix} 1`);
    expect(selectedCsv).not.toContain(`${prefix} 2`);
  });
});
