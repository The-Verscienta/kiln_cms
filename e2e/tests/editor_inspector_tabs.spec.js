// @ts-check
//
// The content editor's inspector rail (#1679) is a kit `.tabs` tablist with
// the WAI-ARIA keyboard model, driven by the same `TabKeys` hook as the Form
// Builder's (assets/js/tab_keys.js): Left/Right move (wrapping), Home/End
// jump, the tab activates as it is focused, and only the selected tab is in
// the Tab order. LiveViewTest cannot run the hook; this spec is where the
// keys are exercised for the editor. It also checks the block chrome's other
// keyboard promise: a control that is faded out shows once it has focus.
const { test, expect, signInAsAdmin, newDraftPage, addBlock } = require("./fixtures");

test.beforeEach(async ({ page }) => {
  await signInAsAdmin(page);
});

test("inspector tabs follow the ARIA tabs keyboard model", async ({ page }) => {
  await newDraftPage(page);

  const tablist = page.getByRole("tablist", { name: "Inspector" });
  const tab = name => tablist.getByRole("tab", { name });

  await expect(tab("Preview")).toHaveAttribute("aria-selected", "true");
  await expect(tab("Settings")).toHaveAttribute("tabindex", "-1");

  await tab("Preview").focus();
  await page.keyboard.press("ArrowRight");
  await expect(tab("Settings")).toHaveAttribute("aria-selected", "true");
  await expect(tab("Settings")).toBeFocused();
  await expect(page.locator("#inspector-panel-settings")).toBeVisible();
  await expect(page.locator("#inspector-panel-preview")).toBeHidden();

  await page.keyboard.press("End");
  await expect(tab("History")).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#inspector-panel-history")).toBeVisible();

  // Wraps: Right from the last tab lands on the first.
  await page.keyboard.press("ArrowRight");
  await expect(tab("Preview")).toHaveAttribute("aria-selected", "true");
  await expect(tab("Preview")).toBeFocused();

  await page.keyboard.press("ArrowLeft");
  await expect(tab("History")).toHaveAttribute("aria-selected", "true");

  await page.keyboard.press("Home");
  await expect(tab("Preview")).toHaveAttribute("aria-selected", "true");
  await expect(tab("Preview")).toBeFocused();
});

test("a faded block control shows once it has keyboard focus", async ({ page }) => {
  await newDraftPage(page);
  await addBlock(page, "rich_text");

  const card = page.locator("#block-0");
  const actions = card.getByRole("group", { name: "Block actions" });
  await expect(actions).toBeAttached();

  // Park the pointer away from the card so hover is not what reveals it.
  await page.mouse.move(0, 0);
  await page.locator("h1").first().click();
  await expect(actions).toHaveCSS("opacity", "0");

  await card.getByRole("button", { name: "Duplicate block" }).focus();
  await expect(actions).toHaveCSS("opacity", "1");
});
