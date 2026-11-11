// @ts-check
//
// A table wider than the screen scrolls sideways inside its `.kiln-table-wrap`,
// and a keyboard user can only scroll what takes focus (#2464). Every wrapper
// that holds a table gets `tabindex="0"`, `role="group"` and a label from the
// renderer (`KilnCMS.ScrollableTables`), which also wraps a bare `legacy_html`
// table that had no wrapper at all. What a unit test cannot see is the browser
// half: that Tab lands on the wrapper, the arrow keys scroll it, and the focus
// ring actually shows. So at phone width, on one published page holding:
//
//   * a Portable Text table, the shape every editor writes today;
//   * a bare `legacy_html` table, TipTap's old shape.
const { test, expect, ADMIN, signInAsAdmin, deleteContentById } = require("./fixtures");

test.use({ viewport: { width: 375, height: 812 } });

const LONG_CELL = "x".repeat(300);

/**
 * Tab from the top of the page until `wrap` has focus, then check it scrolls
 * with ArrowRight and shows a ring.
 * @param {import("@playwright/test").Page} page
 * @param {import("@playwright/test").Locator} wrap
 */
async function tabToAndScroll(page, wrap) {
  await expect(wrap).toHaveAttribute("tabindex", "0");
  await expect(wrap).toHaveAttribute("role", "group");
  await expect(wrap).toHaveAttribute("aria-label", "Scrollable table");

  // The table really overflows at this width, or the rest proves nothing.
  expect(await wrap.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);

  // Start from the top of the document with nothing focused (a click could
  // land on the header's logo link).
  await page.evaluate(() => /** @type {HTMLElement | null} */ (document.activeElement)?.blur());
  let focused = false;
  for (let i = 0; i < 60 && !focused; i++) {
    await page.keyboard.press("Tab");
    focused = await wrap.evaluate(el => el === document.activeElement);
  }
  expect(focused, "Tab never reached the table").toBe(true);

  expect(await wrap.evaluate(el => el.scrollLeft)).toBe(0);
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => wrap.evaluate(el => el.scrollLeft)).toBeGreaterThan(0);

  // Our ring, not the browser's default one: outset, solid, on the page
  // background rather than over the cells' borders.
  const outline = await wrap.evaluate(el => {
    const style = getComputedStyle(el);
    return { style: style.outlineStyle, offset: style.outlineOffset, width: parseFloat(style.outlineWidth) };
  });
  expect(outline.style).toBe("solid");
  expect(outline.offset).toBe("2px");
  expect(outline.width).toBeGreaterThan(0);
}

test.describe("scrollable tables take keyboard focus", () => {
  /** @type {string | undefined} */
  let pageId;

  test.afterEach(async ({ page }) => {
    if (pageId) {
      await signInAsAdmin(page);
      await deleteContentById(page, "page", pageId);
    }
    pageId = undefined;
  });

  test("a Portable Text table and a bare legacy_html table", async ({ page, request }) => {
    const signIn = await request.post("/api/auth/sign_in", {
      data: { email: ADMIN.email, password: ADMIN.password },
    });
    expect(signIn.status(), await signIn.text()).toBe(201);
    const { token } = await signIn.json();

    const headers = {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.api+json",
      "content-type": "application/vnd.api+json",
    };
    const slug = `e2e-table-focus-${Date.now()}`;

    const cell = (/** @type {string} */ text, header = false) => ({
      header,
      children: [{ _type: "span", text, marks: [] }],
    });

    const created = await request.post("/api/json/pages", {
      headers,
      data: {
        data: {
          type: "page",
          attributes: {
            title: "Table focus",
            slug,
            blocks: [
              {
                _type: "rich_text",
                body: [
                  {
                    _type: "table",
                    rows: [
                      { cells: [cell("Name", true), cell("Value", true)] },
                      { cells: [cell("Wide"), cell(LONG_CELL)] },
                    ],
                  },
                ],
              },
              {
                _type: "rich_text",
                body: [],
                legacy_html: `<table><tr><td>Legacy</td><td>${LONG_CELL}</td></tr></table>`,
              },
            ],
          },
        },
      },
    });
    expect(created.status(), await created.text()).toBe(201);
    pageId = (await created.json()).data.id;

    const published = await request.patch(`/api/json/pages/${pageId}/publish`, {
      headers,
      data: { data: { type: "page", id: pageId, attributes: {} } },
    });
    expect(published.status(), await published.text()).toBe(200);

    await page.goto(`/${slug}`);
    const wraps = page.locator(".kiln-block .kiln-table-wrap");
    await expect(wraps).toHaveCount(2);

    const ptWrap = wraps.filter({ hasText: "Wide" });
    await expect(ptWrap.locator("thead th").first()).toHaveText("Name");
    await tabToAndScroll(page, ptWrap);

    await tabToAndScroll(page, wraps.filter({ hasText: "Legacy" }));
  });
});
