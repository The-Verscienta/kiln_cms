// @ts-check
// The content list's status marks (#1323): words by default, the I-Ching
// trigram glyph only for someone who opts in on Your settings.
//
// The LiveView tests cover the markup; this is the journey — the choice made
// on one screen, stored on the account, and read by the content list on the
// next visit — and the screenshots it leaves in test-results/ are how the two
// looks were checked.
const { test, expect, signInAsAdmin, newDraftPage, saveDraft, save } = require("./fixtures");

// "YYYY-MM-DDTHH:MM" for a datetime-local input, `days` from now.
function localInput(days) {
  const at = new Date(Date.now() + days * 86_400_000);
  const pad = n => String(n).padStart(2, "0");
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}T${pad(at.getHours())}:${pad(at.getMinutes())}`;
}

async function chooseMarks(page, marks) {
  await page.goto("/editor/settings");
  const button = page.locator(`#settings-status-marks-${marks}`);
  await button.click();
  await expect(button).toHaveAttribute("aria-pressed", "true");
}

test.describe("content list status marks", () => {
  test.use({ viewport: { width: 1280, height: 900 } });

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
    // The seeded admin is shared by every spec; start from the default.
    await chooseMarks(page, "words");
  });

  // Leave the shared account on the default for whichever spec runs next.
  test.afterEach(async ({ page }) => {
    await chooseMarks(page, "words");
  });

  test("words by default, the trigram glyph once opted in", async ({ page }, testInfo) => {
    const id = await newDraftPage(page);
    await saveDraft(page, { title: `Status marks ${Date.now()}` });

    // A publish date three days out, so the trigram below has a bit set that
    // the state badge does not say.
    await page.getByRole("tab", { name: /settings/i }).click();
    await page.locator('input[id^="scheduled-at-local-"]').fill(localInput(3));
    await save(page);

    await page.goto("/editor?status=draft");
    const row = page.locator(`li[id$="-${id}"]`);

    // Single-locale site: nothing is missing a translation, so no word mark —
    // the schedule is the dated line, which says what will happen.
    await expect(row.locator(`#scheduled-page-${id}`)).toBeVisible();
    await expect(row).toContainText("Publishes");
    await expect(row.locator("[data-status-mark]")).toHaveCount(0);
    await expect(row.locator('svg[role="img"]')).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath("content-list-words.png") });

    await chooseMarks(page, "trigrams");
    await page.locator("#settings-status-marks").screenshot({
      path: testInfo.outputPath("settings-status-marks.png"),
      animations: "disabled",
    });

    await page.goto("/editor?status=draft");
    // xun · wind: not published, translated (one locale), scheduled.
    await expect(row.locator('svg[role="img"]')).toHaveAttribute(
      "aria-label",
      "xun · wind · not published · translated · scheduled",
    );
    await expect(row.locator("[data-status-mark]")).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath("content-list-trigrams.png") });
  });
});
