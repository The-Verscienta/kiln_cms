// @ts-check
// The console shell's grid (Layouts.console/1) as a real browser lays it out.
//
// A usability pass on kilncms.dev reported the sidebar "clipped to a sliver":
// "Home" read "me", "KilnCMS" read "CMS" — labels cut from the LEFT. Neither
// case below is visible to a LiveView test; both are about geometry.
const { test, expect, signInAsAdmin } = require("./fixtures");

// The smallest `aside.side-shell` left edge seen on any frame for `ms`.
function minAsideLeft(page, ms) {
  return page.evaluate(
    duration =>
      new Promise(resolve => {
        const aside = document.querySelector("aside.side-shell");
        const start = performance.now();
        let min = Infinity;
        const sample = () => {
          min = Math.min(min, aside.getBoundingClientRect().left);
          if (performance.now() - start < duration) requestAnimationFrame(sample);
          else resolve(min);
        };
        sample();
      }),
    ms,
  );
}

test.describe("console shell layout", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  // Below 64rem the sidebar is a drawer parked off-canvas with
  // `-translate-x-full`, and its `transition-transform` slides it in. At lg the
  // translate is cancelled — but the transition used to run there too, so a
  // window crossing 64rem (resize, snap, zoom) slid the rail in over ~150ms
  // with its labels cropped from the left. At lg it must simply be there.
  test("crossing into desktop width shows the rail at once, not sliding in", async ({ page }) => {
    await page.setViewportSize({ width: 900, height: 800 });
    await expect
      .poll(() => page.locator("aside.side-shell").evaluate(el => el.getBoundingClientRect().right))
      .toBeLessThanOrEqual(0);

    await page.setViewportSize({ width: 1280, height: 800 });

    expect(await minAsideLeft(page, 300)).toBeGreaterThanOrEqual(0);
  });

  // The content column was a bare `1fr`, whose minimum is its min-content
  // width: one wide descendant — a long <pre>, a wide table — made the whole
  // page scroll sideways, even when that descendant scrolls itself. The column
  // must hold the viewport and leave the scrolling to the wide element.
  test("wide content scrolls inside itself instead of widening the page", async ({ page }) => {
    const result = await page.evaluate(() => {
      const wrap = document.createElement("div");
      wrap.id = "e2e-wide";
      wrap.style.overflowX = "auto";
      const pre = document.createElement("pre");
      pre.textContent = "x".repeat(1500);
      wrap.appendChild(pre);
      document.getElementById("main").prepend(wrap);

      const doc = document.documentElement;
      return {
        pageOverflow: doc.scrollWidth - doc.clientWidth,
        selfScrolls: wrap.scrollWidth > wrap.clientWidth,
        asideLeft: document.querySelector("aside.side-shell").getBoundingClientRect().left,
      };
    });

    expect(result.pageOverflow).toBeLessThanOrEqual(0);
    expect(result.selfScrolls).toBe(true);
    expect(result.asideLeft).toBe(0);
  });
});
