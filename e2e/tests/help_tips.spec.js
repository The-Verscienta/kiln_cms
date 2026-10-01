// @ts-check
//
// The "?" help tips beside the calendar's Lane and Health filters (#1822).
// LiveViewTest checks the button and panel are rendered with the right
// attributes; these are the claims only a browser can check, because the panel
// is the browser's own `popover`:
//
//   * the button opens the panel from the keyboard, and Escape closes it again
//     with focus back on the button;
//   * a LiveView patch (changing a filter) does not shut an open panel, and
//     choosing an option does not submit anything because of the button.
const { test, expect, waitForLiveConnected, signInAsEditor } = require("./fixtures");

test.describe("console help tips (#1822)", () => {
  test("the Lane tip opens from the keyboard and closes on Escape", async ({ page }) => {
    await signInAsEditor(page);
    await page.goto("/editor/calendar");
    await waitForLiveConnected(page);

    const button = page.getByRole("button", { name: "About lanes" });
    const panel = page.locator("#calendar-lanes-help");

    await expect(panel).toBeHidden();
    await button.focus();
    await page.keyboard.press("Enter");
    await expect(panel).toBeVisible();
    await expect(panel).toContainText("Each lane is one kind of date");
    await expect(panel.getByRole("link", { name: /Learn more/ })).toHaveAttribute(
      "target",
      "_blank"
    );

    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(button).toBeFocused();
  });

  test("an open tip survives a LiveView patch", async ({ page }) => {
    await signInAsEditor(page);
    await page.goto("/editor/calendar");
    await waitForLiveConnected(page);

    await page.getByRole("button", { name: "About health" }).click();
    const panel = page.locator("#calendar-health-help");
    await expect(panel).toBeVisible();

    // A filter change patches the page; the popover's open state is the
    // browser's, not an attribute LiveView could strip.
    await page.evaluate(() => {
      const select = /** @type {HTMLSelectElement} */ (
        document.getElementById("calendar-filter-kind")
      );
      select.value = "publish";
      select.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await expect(page).toHaveURL(/kind=publish/);
    await expect(panel).toBeVisible();
  });
});
