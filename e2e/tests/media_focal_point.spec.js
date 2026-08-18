// @ts-check
//
// Media upload + focal point (#1314). Uploads a real (generated) PNG through
// the library's LiveView upload form, opens its detail drawer, moves the focal
// point by pointer and by keyboard, checks it persists across a reload, and
// finally deletes the item (a soft-delete: it lands in the trash).
//
// The focal-point editor is gated on the item's `width`, which
// `KilnCMS.Media.VariantWorker` measures in the background — so this journey
// is also the one that proves the e2e server processes its Oban `:media`
// queue (config/e2e.exs). Locally the worker lands in well under a second;
// the drawer is re-opened until it does.
const zlib = require("zlib");
const { test, expect, signInAsAdmin } = require("./fixtures");

// A valid RGB PNG of `width`×`height` filled with one colour. Built by hand
// (signature + IHDR + IDAT + IEND with real CRCs) so the suite needs no image
// fixture on disk and no image library in the browser process. Big enough that
// a click at a quarter of the width is unambiguous once rendered.
function pngBuffer(width, height, [r, g, b]) {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc32 = buf => {
    let c = 0xffffffff;
    for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const typed = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(typed));
    return Buffer.concat([len, typed, crc]);
  };

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: truecolour
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) row.set([r, g, b], 1 + x * 3);
  const raw = Buffer.concat(Array.from({ length: height }, () => row));

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// "left: 25.0%; top: 75.0%" → { left: 25, top: 75 }
function markerPosition(style) {
  const left = /left:\s*([\d.]+)%/.exec(style || "");
  const top = /top:\s*([\d.]+)%/.exec(style || "");
  return { left: left ? parseFloat(left[1]) : NaN, top: top ? parseFloat(top[1]) : NaN };
}

test.describe("media library", () => {
  const filename = `e2e-focal-${Date.now()}.png`;
  /** @type {string | null} */
  let mediaId = null;

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Best-effort cleanup if the journey failed before its own delete step.
    if (!mediaId) return;
    await page.goto("/media");
    const card = page.locator(`li[id="media-${mediaId}"]`);
    if ((await card.count()) === 0) return;
    page.once("dialog", dialog => dialog.accept());
    await card.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(card).toHaveCount(0);
    mediaId = null;
  });

  test("upload a PNG → set the focal point by pointer and keyboard → it persists → delete", async ({
    page,
  }) => {
    await page.goto("/media");

    // Upload. The file input is visually hidden (`sr-only`), which
    // setInputFiles doesn't mind; the submit button only renders once an
    // entry is staged.
    await page.locator("#upload-form input[type=file]").setInputFiles({
      name: filename,
      mimeType: "image/png",
      buffer: pngBuffer(320, 200, [200, 60, 30]),
    });
    await expect(page.locator("#upload-form").getByText(filename)).toBeVisible();
    await page.getByRole("button", { name: /^upload 1 file$/i }).click();
    await expect(page.locator("#flash-info")).toContainText("Uploaded 1 file.");

    const card = page.locator("#media-grid li").filter({ hasText: filename }).first();
    await expect(card).toBeVisible();
    mediaId = (await card.getAttribute("id"))?.replace(/^media-/, "") ?? null;
    expect(mediaId).toBeTruthy();

    // Open the detail drawer. The focal editor appears once the variant worker
    // has measured the image; the drawer's own item is not refreshed by that
    // broadcast, so re-open until it is there.
    const focalEditor = page.locator(`#focal-editor-${mediaId}`);
    await expect(async () => {
      await page.goto(`/media?id=${mediaId}`);
      await expect(focalEditor).toBeVisible({ timeout: 1_500 });
    }).toPass({ timeout: 30_000 });

    const marker = focalEditor.locator("span");
    const img = focalEditor.locator("img");
    // Untouched: the point sits at the centre.
    expect(markerPosition(await marker.getAttribute("style"))).toEqual({ left: 50, top: 50 });
    // Wait for the image to render at its final size before deriving a click.
    await expect.poll(async () => (await img.boundingBox())?.width ?? 0).toBeGreaterThan(50);

    // Pointer: click a quarter across and three-quarters down. The hook turns
    // the click into fractions of the rendered image, so the marker lands
    // there — a couple of percent of tolerance for pixel rounding.
    const box = await img.boundingBox();
    if (!box) throw new Error("focal image has no box");
    await img.click({ position: { x: box.width * 0.25, y: box.height * 0.75 } });
    const near = (pos, left, top) => Math.abs(pos.left - left) < 3 && Math.abs(pos.top - top) < 3;
    await expect
      .poll(async () => near(markerPosition(await marker.getAttribute("style")), 25, 75), {
        message: "focal marker should follow the click to ~(25%, 75%)",
      })
      .toBe(true);
    let pos = markerPosition(await marker.getAttribute("style"));

    // Keyboard: the editor is focusable; each arrow nudges by 5%.
    await focalEditor.focus();
    await page.keyboard.press("ArrowRight");
    await expect
      .poll(async () => markerPosition(await marker.getAttribute("style")).left)
      .toBeGreaterThan(pos.left + 4);
    await page.keyboard.press("ArrowUp");
    await expect
      .poll(async () => markerPosition(await marker.getAttribute("style")).top)
      .toBeLessThan(pos.top - 4);
    pos = markerPosition(await marker.getAttribute("style"));

    // Persisted: a fresh load of the same drawer renders the same point, from
    // the record rather than from anything the browser remembered.
    await page.goto(`/media?id=${mediaId}`);
    await expect(focalEditor).toBeVisible();
    const reloaded = markerPosition(await marker.getAttribute("style"));
    expect(Math.abs(reloaded.left - pos.left)).toBeLessThan(0.5);
    expect(Math.abs(reloaded.top - pos.top)).toBeLessThan(0.5);
    expect(parseFloat((await focalEditor.getAttribute("data-focal-x")) || "")).toBeCloseTo(
      pos.left / 100,
      2,
    );

    // Delete from the grid: a native confirm names the file, and the item goes
    // to the trash (soft-delete), leaving the grid.
    await page.goto("/media");
    const cardAgain = page.locator(`li[id="media-${mediaId}"]`);
    await expect(cardAgain).toBeVisible();
    page.once("dialog", async dialog => {
      expect(dialog.message()).toContain(filename);
      await dialog.accept();
    });
    await cardAgain.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(page.locator("#flash-info")).toContainText(`Moved ${filename} to trash.`);
    await expect(cardAgain).toHaveCount(0);
    mediaId = null;
  });
});
