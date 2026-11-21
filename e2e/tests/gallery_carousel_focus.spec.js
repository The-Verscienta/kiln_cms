// @ts-check
//
// A carousel gallery scrolls sideways inside `.kiln-gallery-items`, and a
// keyboard user can only scroll what takes focus (#2590). The renderer gives
// the container `tabindex="0"`, `role="group"` and a label; this checks the
// browser half at phone width: Tab lands on it, ArrowRight scrolls it, and the
// ring shows.
const { test, expect, ADMIN, signInAsAdmin, deleteContentById } = require("./fixtures");

test.use({ viewport: { width: 375, height: 812 } });

test.describe("a carousel gallery takes keyboard focus", () => {
  /** @type {string | undefined} */
  let pageId;

  test.afterEach(async ({ page }) => {
    if (pageId) {
      await signInAsAdmin(page);
      await deleteContentById(page, "page", pageId);
    }
    pageId = undefined;
  });

  test("Tab reaches the carousel and ArrowRight scrolls it", async ({ page, request }) => {
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
    const slug = `e2e-gallery-focus-${Date.now()}`;
    const images = Array.from({ length: 6 }, (_, i) => ({
      url: `/images/app-icon-192.png?n=${i}`,
      alt: `Image ${i}`,
      caption: "",
    }));

    const created = await request.post("/api/json/pages", {
      headers,
      data: {
        data: {
          type: "page",
          attributes: {
            title: "Gallery focus",
            slug,
            blocks: [{ _type: "gallery", layout: "carousel", images }],
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
    const carousel = page.locator(".kiln-gallery-items");
    await expect(carousel).toHaveAttribute("tabindex", "0");
    await expect(carousel).toHaveAttribute("role", "group");
    await expect(carousel).toHaveAttribute("aria-label", "Image gallery");
    expect(await carousel.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);

    await page.evaluate(() => /** @type {HTMLElement | null} */ (document.activeElement)?.blur());
    let focused = false;
    for (let i = 0; i < 60 && !focused; i++) {
      await page.keyboard.press("Tab");
      focused = await carousel.evaluate(el => el === document.activeElement);
    }
    expect(focused, "Tab never reached the carousel").toBe(true);

    expect(await carousel.evaluate(el => el.scrollLeft)).toBe(0);
    await page.keyboard.press("ArrowRight");
    await expect.poll(() => carousel.evaluate(el => el.scrollLeft)).toBeGreaterThan(0);

    const outline = await carousel.evaluate(el => {
      const style = getComputedStyle(el);
      return { style: style.outlineStyle, width: parseFloat(style.outlineWidth) };
    });
    expect(outline.style).toBe("solid");
    expect(outline.width).toBeGreaterThan(0);
  });
});
