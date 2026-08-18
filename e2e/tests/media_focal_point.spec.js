// @ts-check
//
// Media upload + focal point (#1314). Uploads a real PNG through the library's
// LiveView upload form, opens its detail drawer, moves the focal point by
// pointer and by keyboard, checks it persists across a reload, and finally
// deletes the item (a soft-delete: it lands in the trash).
//
// The focal-point editor is gated on the item's `width`, which
// `KilnCMS.Media.VariantWorker` measures in the background — so this journey
// is also the one that proves the e2e server processes its Oban `:media`
// queue (config/e2e.exs), and that an already-open drawer follows the worker's
// broadcast rather than needing to be closed and reopened.
const fs = require("fs");
const path = require("path");
const { test, expect, signInAsAdmin } = require("./fixtures");

// A real PNG the repo already ships (278×379). Big enough that a click a
// quarter of the way across is unambiguous once rendered.
const PNG_PATH = path.join(__dirname, "../../priv/static/images/logo-mark.png");

// Deletes a media item from the grid: a native confirm names the file, and
// the item goes to the trash (soft-delete), leaving the grid. Returns the
// confirm's message so a caller can assert on it after the fact — asserting
// inside the dialog handler would leave the confirm open on a mismatch and
// hang the click until the test timeout.
async function deleteMedia(page, id) {
  await page.goto("/media");
  const card = page.locator(`li[id="media-${id}"]`);
  if ((await card.count()) === 0) return null;
  let message = null;
  page.once("dialog", dialog => {
    message = dialog.message();
    return dialog.accept();
  });
  await card.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(card).toHaveCount(0);
  return message;
}

test.describe("media library", () => {
  /** @type {string} */
  let filename;
  /** @type {string | null} */
  let mediaId = null;

  test.beforeEach(async ({ page }) => {
    filename = `e2e-focal-${Date.now()}.png`;
    mediaId = null;
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Best-effort cleanup if the journey failed before its own delete step.
    if (mediaId) await deleteMedia(page, mediaId);
    mediaId = null;
  });

  test("upload a PNG → set the focal point by pointer and keyboard → it persists → delete", async ({
    page,
  }) => {
    // Two background waits (variant worker, then the persisted re-read) on top
    // of the upload: give it the tripled budget rather than racing the 30 s.
    test.slow();
    await page.goto("/media");

    // Upload. The file input is visually hidden (`sr-only`), which
    // setInputFiles doesn't mind; the submit button only renders once an
    // entry is staged.
    await page.locator("#upload-form input[type=file]").setInputFiles({
      name: filename,
      mimeType: "image/png",
      buffer: fs.readFileSync(PNG_PATH),
    });
    await expect(page.locator("#upload-form").getByText(filename)).toBeVisible();
    await page.getByRole("button", { name: /^upload 1 file$/i }).click();
    await expect(page.locator("#flash-info")).toContainText("Uploaded 1 file.");

    const card = page.locator("#media-grid li").filter({ hasText: filename }).first();
    await expect(card).toBeVisible();
    mediaId = (await card.getAttribute("id"))?.replace(/^media-/, "") ?? null;
    expect(mediaId).toBeTruthy();

    // Open the detail drawer straight away. The focal editor appears once the
    // variant worker has measured the image, and the open drawer must pick
    // that up over PubSub on its own — no reload.
    await card.getByRole("button", { name: `View details for ${filename}` }).click();
    const focalEditor = page.locator(`#focal-editor-${mediaId}`);
    await expect(focalEditor).toBeVisible({ timeout: 30_000 });

    // The editor carries the current point as data attributes, re-rendered
    // from the record on every server patch — the hook never moves anything
    // client-side, so these are the truth about what was stored.
    const focal = async () => ({
      x: parseFloat((await focalEditor.getAttribute("data-focal-x")) ?? "NaN"),
      y: parseFloat((await focalEditor.getAttribute("data-focal-y")) ?? "NaN"),
    });
    const near = (a, b) => Math.abs(a - b) < 0.03;

    // Untouched: the point sits at the centre, and so does the marker.
    expect(await focal()).toEqual({ x: 0.5, y: 0.5 });
    await expect(focalEditor.locator("span")).toHaveAttribute("style", /left: 50\.0%; top: 50\.0%/);

    // Wait for the image to render at its final size before deriving a click.
    const img = focalEditor.locator("img");
    await expect.poll(async () => (await img.boundingBox())?.width ?? 0).toBeGreaterThan(50);

    // Pointer: click a quarter across and three-quarters down. The hook turns
    // the click into fractions of the rendered image, so the point lands there
    // — a few percent of tolerance for pixel rounding.
    const box = await img.boundingBox();
    if (!box) throw new Error("focal image has no box");
    await img.click({ position: { x: box.width * 0.25, y: box.height * 0.75 } });
    await expect
      .poll(async () => {
        const p = await focal();
        return near(p.x, 0.25) && near(p.y, 0.75);
      }, { message: "focal point should follow the click to ~(0.25, 0.75)" })
      .toBe(true);
    let pos = await focal();

    // Keyboard: the editor is focusable; each arrow nudges by exactly 5%.
    await focalEditor.focus();
    await page.keyboard.press("ArrowRight");
    await expect.poll(async () => (await focal()).x).toBeCloseTo(pos.x + 0.05, 2);
    await page.keyboard.press("ArrowUp");
    await expect.poll(async () => (await focal()).y).toBeCloseTo(pos.y - 0.05, 2);
    pos = await focal();

    // Persisted: a fresh load of the same drawer renders the same point, from
    // the record rather than from anything the browser remembered.
    await page.goto(`/media?id=${mediaId}`);
    await expect(focalEditor).toBeVisible();
    const reloaded = await focal();
    expect(reloaded.x).toBeCloseTo(pos.x, 3);
    expect(reloaded.y).toBeCloseTo(pos.y, 3);

    // Delete from the grid; the confirm named the file and the flash says
    // "trash", not "gone".
    const message = await deleteMedia(page, mediaId);
    expect(message).toContain(filename);
    await expect(page.locator("#flash-info")).toContainText(`Moved ${filename} to trash.`);
    mediaId = null;
  });
});
