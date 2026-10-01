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
const {
  test,
  expect,
  signInAsAdmin,
  signInAsEditor,
  newGuardedContext,
  save,
  deleteContentById,
} = require("./fixtures");

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

  // An editor who may not publish proposes the day; an admin's "Use this
  // date" (a client-side copy into the schedule field, which no LiveView
  // test can drive) plus Save makes it the schedule and clears the proposal.
  test("an editor's + proposes the day, and an admin turns it into the schedule", async ({
    page,
    browser,
  }) => {
    const day = target();
    const title = `Proposed ${Date.now()}`;
    let id;

    const { context, page: editorPage } = await newGuardedContext(browser);
    try {
      await signInAsEditor(editorPage);
      await editorPage.goto(`/editor/calendar?at=${isoDate(day)}`);
      await editorPage.getByRole("button", { name: `New content on ${dayLabel(day)}` }).click();
      const dialog = editorPage.getByRole("dialog", { name: `New on ${dayLabel(day)}` });
      await dialog.getByRole("link", { name: "Page", exact: true }).click();
      await editorPage.waitForURL(/\/editor\/content\/page\/new\?scheduled_at=/);

      const note = editorPage.locator("#new-draft-scheduled-at");
      // A site that lets editors publish schedules for them instead; this
      // journey is about the other kind of site.
      test.skip(
        (await note.getAttribute("data-date-kind")) !== "proposed_publish_at",
        "the seeded site lets editors publish",
      );
      await expect(note).toContainText("an admin confirms the date");

      await editorPage.fill('input[name="form[title]"]', title);
      await editorPage.waitForURL(/\/editor\/content\/page\/[0-9a-f-]{36}$/);
      id = new URL(editorPage.url()).pathname.split("/").pop();
    } finally {
      await context.close();
    }

    try {
      await signInAsAdmin(page);
      await page.goto(`/editor/calendar?at=${isoDate(day)}`);
      const chip = page.locator(`li[data-event-id="${id}"][data-event-kind="proposed"]`);
      await expect(chip).toContainText("Proposed:");
      await expect(chip).not.toHaveAttribute("data-reschedulable", "true");

      await page.goto(`/editor/content/page/${id}`);
      await page.click('[phx-click="switch_inspector_tab"][phx-value-tab="settings"]');
      await page.click("#use-proposed-publish-at");
      await expect(page.locator('[data-local-input][id^="scheduled-at-local"]')).not.toHaveValue("");
      await save(page);

      await expect(page.locator("#proposed-publish-at-note")).toHaveCount(0);
      await page.goto(`/editor/calendar?at=${isoDate(day)}`);
      await expect(
        page.locator(`li[data-event-id="${id}"][data-event-kind="publish"]`),
      ).toBeVisible();
      await expect(page.locator(`li[data-event-id="${id}"][data-event-kind="proposed"]`)).toHaveCount(
        0,
      );
    } finally {
      if (id) await deleteContentById(page, "page", id);
    }
  });
});
