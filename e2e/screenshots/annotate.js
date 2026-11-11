// @ts-check
// Numbered callouts for the guide screenshots (docs/editorial-workflow.md,
// #2158). `annotate(page, markers)` draws a ring around each element and a
// numbered badge at its top-left corner, takes the shot, then removes them, so
// the page under the overlay is untouched for the next step.
//
// The overlay is a fixed layer on `document.body`, outside `[data-phx-main]`,
// so a LiveView patch landing mid-shot cannot remove or re-render it, and it
// takes no clicks (`pointer-events: none`). Styles are set through the CSSOM
// rather than a `style` attribute, which the console's CSP refuses.
//
// The numbers are the guide's: each image is followed by a numbered list that
// says what each badge marks, so the picture never carries text of its own.

// Rose on white: legible on the console's light surfaces and on its tinted
// pills. The badge is the ring's color with a white border, so it reads on a
// dark button too.
const COLOR = "#e11d48";
const BADGE = 28;
// Room the ring keeps around the element, and the shot keeps around the rings.
const RING_GAP = 4;
const MAX_MARKERS = 3;

/**
 * @param {import("@playwright/test").Page} page
 * @param {{ locator: import("@playwright/test").Locator, n: number }[]} markers
 * @param {{ path: string, clip?: { x: number, y: number, width: number, height: number } }} shot
 */
async function annotate(page, markers, shot) {
  if (markers.length > MAX_MARKERS) {
    throw new Error(`annotate: at most ${MAX_MARKERS} markers per shot, got ${markers.length}`);
  }

  // Scroll first, then measure every marker in a second pass: the rings are
  // fixed to viewport coordinates, so a box read before a later marker's
  // scroll would be drawn where its element used to be.
  for (const { locator } of markers) await locator.scrollIntoViewIfNeeded();

  const boxes = [];
  for (const { locator, n } of markers) {
    const box = await locator.boundingBox();
    if (!box) throw new Error(`annotate: marker ${n} is not visible`);
    boxes.push({ ...box, n });
  }

  await page.evaluate(
    ({ boxes, color, badge, gap }) => {
      const layer = document.createElement("div");
      layer.id = "kiln-annotations";
      Object.assign(layer.style, {
        position: "fixed",
        inset: "0",
        pointerEvents: "none",
        zIndex: "2147483647",
      });

      for (const { x, y, width, height, n } of boxes) {
        const ring = document.createElement("div");
        Object.assign(ring.style, {
          position: "fixed",
          left: `${x - gap}px`,
          top: `${y - gap}px`,
          width: `${width + gap * 2}px`,
          height: `${height + gap * 2}px`,
          border: `3px solid ${color}`,
          borderRadius: "8px",
          boxShadow: "0 0 0 2px #fff",
          boxSizing: "border-box",
        });

        const label = document.createElement("div");
        label.textContent = String(n);
        Object.assign(label.style, {
          position: "fixed",
          // Mostly outside the ring's top-left corner, so it hides the
          // ring's corner rather than the first letter of a label.
          left: `${Math.max(x - gap - badge * 0.75, 2)}px`,
          top: `${Math.max(y - gap - badge * 0.75, 2)}px`,
          width: `${badge}px`,
          height: `${badge}px`,
          borderRadius: "9999px",
          background: color,
          color: "#fff",
          border: "2px solid #fff",
          boxShadow: "0 1px 3px rgba(0,0,0,.35)",
          boxSizing: "border-box",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          font: "700 14px/1 ui-sans-serif, system-ui, sans-serif",
        });

        layer.append(ring, label);
      }

      document.body.append(layer);
    },
    { boxes, color: COLOR, badge: BADGE, gap: RING_GAP },
  );

  try {
    await page.screenshot({ path: shot.path, type: "jpeg", quality: 90, clip: shot.clip });
  } finally {
    await page.evaluate(() => document.getElementById("kiln-annotations")?.remove());
  }
}

module.exports = { annotate };
