// @ts-check
//
// A code block wider than the screen scrolls sideways, and a keyboard user can
// only scroll what takes focus (#2164). Every content `<pre>` gets
// `tabindex="0"`, `role="group"` and a label from the renderer
// (`KilnCMS.CodeBlocks`), and the app's own `<pre>`s carry the same by hand.
// What a unit test cannot see is the browser half: that Tab lands on the
// block, the arrow keys scroll it, and the focus ring actually shows. So at
// phone width:
//
//   * a published page whose code block is stored as `legacy_html` — the shape
//     the docs publisher writes, with a 300-character line;
//   * `/developers`, whose examples are the app's own templates.
const { test, expect, ADMIN, signInAsAdmin, deleteContentById } = require("./fixtures");

test.use({ viewport: { width: 375, height: 812 } });

const LONG_LINE = "x".repeat(300);

/**
 * Tab from the top of the page until `pre` has focus, then check it scrolls
 * with ArrowRight and shows a ring.
 * @param {import("@playwright/test").Page} page
 * @param {import("@playwright/test").Locator} pre
 */
async function tabToAndScroll(page, pre) {
  await expect(pre).toHaveAttribute("tabindex", "0");
  await expect(pre).toHaveAttribute("role", "group");
  await expect(pre).toHaveAttribute("aria-label", "Code sample");

  // The block really overflows at this width, or the rest proves nothing.
  expect(await pre.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);

  // Start from the top of the document with nothing focused (a click could
  // land on the header's logo link).
  await page.evaluate(() => /** @type {HTMLElement | null} */ (document.activeElement)?.blur());
  let focused = false;
  for (let i = 0; i < 60 && !focused; i++) {
    await page.keyboard.press("Tab");
    focused = await pre.evaluate(el => el === document.activeElement);
  }
  expect(focused, "Tab never reached the code block").toBe(true);

  expect(await pre.evaluate(el => el.scrollLeft)).toBe(0);
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => pre.evaluate(el => el.scrollLeft)).toBeGreaterThan(0);

  // Our ring, not the browser's default one: Chromium's own `:focus-visible`
  // outline is neither inset nor necessarily solid.
  const outline = await pre.evaluate(el => {
    const style = getComputedStyle(el);
    return { style: style.outlineStyle, offset: style.outlineOffset, width: parseFloat(style.outlineWidth) };
  });
  expect(outline.style).toBe("solid");
  expect(outline.offset).toBe("-2px");
  expect(outline.width).toBeGreaterThan(0);
}

test.describe("scrollable code blocks take keyboard focus", () => {
  /** @type {string | undefined} */
  let pageId;

  test.afterEach(async ({ page }) => {
    if (pageId) {
      await signInAsAdmin(page);
      await deleteContentById(page, "page", pageId);
    }
    pageId = undefined;
  });

  test("a published page's legacy_html code block", async ({ page, request }) => {
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
    const slug = `e2e-code-focus-${Date.now()}`;

    // `<em>` inside the code is what Portable Text cannot hold, so the block
    // stays `legacy_html` — the docs publisher's shape.
    const created = await request.post("/api/json/pages", {
      headers,
      data: {
        data: {
          type: "page",
          attributes: {
            title: "Code focus",
            slug,
            blocks: [
              { _type: "rich_text", body: [], legacy_html: "<p>Before the code.</p>" },
              {
                _type: "rich_text",
                body: [],
                legacy_html: `<pre><code class="language-elixir">IO.puts(<em>1</em>) # ${LONG_LINE}</code></pre>`,
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
    const pre = page.locator(".kiln-block pre").first();
    await expect(pre.locator("code")).toHaveClass(/language-elixir/);
    await tabToAndScroll(page, pre);
  });

  test("/developers examples", async ({ page }) => {
    await page.goto("/developers");
    await tabToAndScroll(page, page.locator("#json-api pre"));
  });
});
