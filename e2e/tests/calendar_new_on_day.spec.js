// @ts-check
//
// Starting new content from a day on the editorial calendar (#1812).
//
// `KilnCMSWeb.CalendarLiveTest` and `ContentEditorNewDraftTest` cover the
// server half: which days offer "+", what the picker lists, and that the
// `?scheduled_at=` link is written on the first commit. What only a browser
// shows is the journey itself: the "+" is reachable and named for a keyboard
// user, the picker is a real dialog that Escape closes, and the scheduling
// field of the editor it opens holds the clicked day.
const { test, expect, signInAsAdmin, deleteContentById } = require("./fixtures");

// The 15th of next month: always in the future, always inside the rendered
// month (the same anchor `calendar_drag.spec.js` and `CalendarLiveTest` use).
function target() {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth() + 1, 15, 12, 0);
}

const pad = n => String(n).padStart(2, "0");
const isoDate = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const dayLabel = d => `${d.getDate()} ${d.toLocaleString("en-GB", { month: "long" })}`;

test.describe("calendar: new content on a day", () => {
  test("+ on a day opens a type picker, and the new page is scheduled for that day", async ({
    page,
  }) => {
    const day = target();
    let id;

    try {
      await signInAsAdmin(page);
      await page.goto(`/editor/calendar?at=${isoDate(day)}`);

      const plus = page.getByRole("button", { name: `New content on ${dayLabel(day)}` });
      await expect(plus).toBeVisible();

      // Keyboard first: the button is focusable and Enter opens the dialog,
      // which Escape closes again.
      await plus.focus();
      await page.keyboard.press("Enter");
      const dialog = page.getByRole("dialog", { name: `New on ${dayLabel(day)}` });
      await expect(dialog).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(dialog).toBeHidden();

      await plus.click();
      await expect(dialog).toBeVisible();
      await dialog.getByRole("link", { name: "Page", exact: true }).click();

      await page.waitForURL(/\/editor\/content\/page\/new\?scheduled_at=/);
      await expect(page.locator("#new-draft-scheduled-at")).toContainText("09:00 UTC");

      await page.fill('input[name="form[title]"]', `Planned ${Date.now()}`);
      await page.waitForURL(/\/editor\/content\/page\/[0-9a-f-]{36}$/);
      id = new URL(page.url()).pathname.split("/").pop();

      // The full editor's schedule field carries the clicked day.
      await expect(page.locator('input[type="hidden"][name$="[scheduled_at]"]')).toHaveAttribute(
        "value",
        new RegExp(`^${isoDate(day)}`),
      );
    } finally {
      if (id) await deleteContentById(page, "page", id);
    }
  });
});
