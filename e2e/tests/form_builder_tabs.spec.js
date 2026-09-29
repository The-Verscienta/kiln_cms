// @ts-check
//
// The Form Builder's section switcher (#1680) is a kit `.tabs` tablist with
// the WAI-ARIA keyboard model: Left/Right move (wrapping), Home/End jump, the
// tab activates as it is focused, and only the selected tab is in the Tab
// order. The keys live in a JS hook (assets/js/tab_keys.js, shared with the
// content editor's inspector rail), which LiveViewTest cannot run — this spec
// and editor_inspector_tabs.spec.js are where they are exercised.
const { test, expect, signInAsAdmin, waitForLiveConnected } = require("./fixtures");

test("form builder tabs follow the ARIA tabs keyboard model", async ({ page }) => {
  await signInAsAdmin(page);

  await page.goto("/editor/forms");
  await waitForLiveConnected(page);
  const slug = `e2e-tabs-${Date.now()}`;
  await page.fill("#form-name", "E2E tabs");
  await page.fill('input[name="form[slug]"]', slug);
  await page.locator('form[phx-submit="create_form"] button[type="submit"]').click();
  await expect(page).toHaveURL(/\/editor\/forms\/[0-9a-f-]{36}$/);
  await waitForLiveConnected(page);

  const tablist = page.getByRole("tablist", { name: "Form sections" });
  const tab = name => tablist.getByRole("tab", { name });

  await expect(tab("Fields")).toHaveAttribute("aria-selected", "true");
  await expect(tab("General")).toHaveAttribute("tabindex", "-1");

  await tab("Fields").focus();
  await page.keyboard.press("ArrowRight");
  await expect(tab("General")).toHaveAttribute("aria-selected", "true");
  await expect(tab("General")).toBeFocused();
  await expect(page.getByRole("tabpanel")).toHaveAttribute(
    "aria-labelledby",
    "form-builder-tab-general",
  );

  await page.keyboard.press("End");
  await expect(tab("Entries")).toHaveAttribute("aria-selected", "true");

  // Wraps: Right from the last tab lands on the first.
  await page.keyboard.press("ArrowRight");
  await expect(tab("Fields")).toHaveAttribute("aria-selected", "true");

  await page.keyboard.press("ArrowLeft");
  await expect(tab("Entries")).toHaveAttribute("aria-selected", "true");

  await page.keyboard.press("Home");
  await expect(tab("Fields")).toHaveAttribute("aria-selected", "true");
  await expect(tab("Fields")).toBeFocused();
});
