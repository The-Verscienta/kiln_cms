// @ts-check
// Product screenshots for the signed-out home page. Not a test — see
// ../screenshots.config.js for how and when to run it. Seed the showcase
// content first (showcase_seeds.exs) or the console photographs as empty.
//
// Output: the raw 2880x1800 captures go to e2e/screenshots/raw/ (gitignored,
// never served). They are NOT what the site ships: after a capture run
//
//     scripts/optimize_home_images.sh
//
// which derives the WebP + JPEG variants under priv/static/images/home/ (the
// only files the home page references; see its header for tools and sizes).
const fs = require("fs");
const path = require("path");
const { test, signInAsAdmin } = require("../tests/fixtures");

const OUT = path.resolve(__dirname, "raw");

// JPEG, not PNG: a 2x console screenshot is ~2 MB as PNG and ~300 KB here;
// optimize_home_images.sh shrinks it further for the home page.
async function shoot(page, name) {
  fs.mkdirSync(OUT, { recursive: true });
  // Let LiveView finish patching and any fade-in settle before the capture.
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, `${name}.jpg`), type: "jpeg", quality: 82 });
}

test("capture the console for the home page", async ({ page }) => {
  await signInAsAdmin(page);

  await page.goto("/editor");
  await shoot(page, "content");

  await page.getByRole("link", { name: "Welcome to Tidewater", exact: true }).first().click();
  await page.waitForURL(/\/editor\/(pages|content)\//);
  await shoot(page, "editor");

  await page.goto("/editor/calendar");
  await shoot(page, "calendar");

  // Past the upload dropzone, so the frame is the library itself. The offset
  // clears the console's sticky top bar, so the "Library" heading stays in shot.
  await page.goto("/media");
  await page.getByRole("heading", { name: /^Library/ }).evaluate((el) => {
    window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 110);
  });
  await shoot(page, "media");
});
