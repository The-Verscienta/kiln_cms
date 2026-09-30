// @ts-check
//
// The media library raises no Chrome DevTools "Issues" of the kinds a beta
// tester reported (#1804): an interactive element inside a <summary>, and a
// form field with neither id nor name (or a label tied to nothing).
//
// These are Chrome's own audits, read over the DevTools protocol
// (`Audits.issueAdded`), so the check is the browser's rather than a selector
// that approximates it — `test/kiln_cms_web/summary_interactive_content_test.exs`
// is that approximation, across more pages. Playwright's bundled Chromium
// reports the <summary> audit; the form-field audits appear only in a full
// Chrome build, so there they are asserted when present and ignored otherwise.
const fs = require("fs");
const path = require("path");
const { test, expect, signInAsAdmin } = require("./fixtures");

const PNG_PATH = path.join(__dirname, "../../priv/static/images/logo-mark.png");

const WATCHED = new Set([
  "InteractiveContentSummaryDescendant",
  "FormEmptyIdAndNameAttributesForInputError",
  "FormLabelHasNeitherForNorNestedInputError",
]);

// Runs `action` with the Audits domain on and returns the watched issues it
// raised, each as `{reason, html}` naming the offending node.
async function auditIssues(page, action) {
  const cdp = await page.context().newCDPSession(page);
  const issues = [];
  cdp.on("Audits.issueAdded", ({ issue }) => issues.push(issue.details || {}));
  await cdp.send("DOM.enable");
  await cdp.send("Audits.enable");
  await action();
  // Issues are reported asynchronously after layout.
  await page.waitForTimeout(1000);
  await cdp.send("DOM.getDocument", { depth: -1 });

  const found = [];
  for (const d of issues) {
    const ea = d.elementAccessibilityIssueDetails;
    const g = d.genericIssueDetails;
    const reason = (ea && ea.elementAccessibilityIssueReason) || (g && g.errorType);
    if (!WATCHED.has(reason)) continue;
    const nodeId = (ea && ea.nodeId) || (g && g.violatingNodeId);
    let html = "(node gone)";
    if (nodeId) {
      html = await cdp
        .send("DOM.getOuterHTML", { backendNodeId: nodeId })
        .then(r => r.outerHTML.slice(0, 300))
        .catch(() => "(node gone)");
    }
    found.push({ reason, html });
  }
  await cdp.detach();
  return found;
}

test.describe("media library DevTools issues", () => {
  /** @type {string | null} */
  let mediaId = null;

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    if (!mediaId) return;
    await page.goto("/media");
    const card = page.locator(`li[id="media-${mediaId}"]`);
    if ((await card.count()) === 0) return;
    page.once("dialog", dialog => dialog.accept());
    await card.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(card).toHaveCount(0);
    mediaId = null;
  });

  // Without this, a protocol change that stopped the audits arriving would
  // pass every assertion below.
  test("the audit reports a control inside a <summary>", async ({ page }) => {
    await page.goto("/media");

    const issues = await auditIssues(page, async () => {
      await page.evaluate(() => {
        const probe = document.createElement("div");
        probe.innerHTML = '<details><summary>x <button type="button">b</button></summary></details>';
        document.body.append(probe);
      });
    });

    expect(issues.map(i => i.reason)).toContain("InteractiveContentSummaryDescendant");
  });

  test("the library, an upload and the detail drawer raise none", async ({ page }) => {
    test.slow();
    const filename = `e2e-issues-${Date.now()}.png`;

    const library = await auditIssues(page, async () => {
      await page.goto("/media");
      await page.locator("#upload-form input[type=file]").setInputFiles({
        name: filename,
        mimeType: "image/png",
        buffer: fs.readFileSync(PNG_PATH),
      });
      await page.getByRole("button", { name: /^upload 1 file$/i }).click();
      await expect(page.locator("#flash-info")).toContainText("Uploaded 1 file.");
    });
    expect(library).toEqual([]);

    const card = page.locator("#media-grid li").filter({ hasText: filename }).first();
    mediaId = (await card.getAttribute("id"))?.replace(/^media-/, "") ?? null;
    expect(mediaId).toBeTruthy();

    const drawer = await auditIssues(page, async () => {
      await page.goto(`/media?id=${mediaId}`);
      await expect(page.locator("#media-item-url")).toBeVisible();
    });
    expect(drawer).toEqual([]);
  });
});
