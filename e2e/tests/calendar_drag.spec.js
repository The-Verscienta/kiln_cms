// @ts-check
//
// Rescheduling from the editorial calendar (#1314's last journey, #1332's
// server twin).
//
// `KilnCMSWeb.CalendarLiveTest` pushes `reschedule` directly, so it proves what
// the server does with the event and nothing about how one is produced. Both
// producers live in the `CalendarDrag` hook and are unreachable from a LiveView
// test: the SortableJS drop, and the arrow-key nudge whose UTC-noon arithmetic
// exists so adding a day near a DST boundary does not land on the wrong one.
// The third case here is the absence of an affordance — a lane the server would
// refuse must not offer a handle in the first place.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  saveDraft,
  deleteContentById,
} = require("./fixtures");

// The 15th of next month at midday. Two properties matter and neither is
// incidental:
//
//   * **next month**, so the fixture is always in the future — the server
//     refuses a move into the past, and `+1`/`+2` from the 15th stay inside the
//     rendered month whatever today is (the same anchor `CalendarLiveTest`
//     uses, and for the same reason).
//   * **midday**, because the editor's scheduling field takes wall-clock local
//     time and stores the UTC instant, while the calendar plots the UTC date.
//     At 12:00 those agree for every real offset; at 00:30 they would not, and
//     the spec would fail on a machine west of Greenwich for reasons having
//     nothing to do with dragging.
function scheduleTarget() {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth() + 1, 15, 12, 0);
}

const pad = n => String(n).padStart(2, "0");
const isoDate = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const localValue = d => `${isoDate(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const dayAfter = d => new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 12, 0);

// A draft page scheduled to publish at `at`, which is what puts a reschedulable
// `publish` chip on the calendar. The scheduling field lives in the editor's
// Settings inspector tab, which is not the tab that opens.
async function schedulePage(page, { title, slug, at }) {
  const id = await newDraftPage(page);

  await page.click('[phx-click="switch_inspector_tab"][phx-value-tab="settings"]');
  const scheduledAt = page.locator('[data-local-input][id^="scheduled-at-local"]');
  await expect(scheduledAt).toBeVisible();
  await scheduledAt.fill(localValue(at));

  await saveDraft(page, { title, slug });
  return id;
}

// SortableJS drives its drops with the browser's native HTML5 drag events, not
// with bare mouse moves — a hand-rolled `mouse.down`/`move`/`up` sequence never
// fires `onEnd`, because Chromium only raises `dragstart` for input it has
// recognised as a drag. Playwright's own `dragTo` sets that interception up, so
// it is the one that works here; the `targetPosition` keeps the drop inside the
// cell rather than on whatever chip already sits at its centre.
async function dragTo(chip, cell) {
  await chip.dragTo(cell, { targetPosition: { x: 8, y: 8 } });
}

const chipFor = (page, title) =>
  page.locator(`[data-reschedulable="true"]`).filter({ hasText: title });

const cellFor = (page, date) => page.locator(`[data-calendar-drop="${isoDate(date)}"]`);

test.describe("calendar rescheduling", () => {
  test("a chip dragged to another day moves the schedule, and it sticks", async ({ page }) => {
    const at = scheduleTarget();
    const moved = dayAfter(at);
    const title = `Drag ${Date.now()}`;
    let id;

    try {
      await signInAsAdmin(page);
      id = await schedulePage(page, { title, slug: `drag-${Date.now()}`, at });

      await page.goto(`/editor/calendar?at=${isoDate(at)}`);
      const chip = chipFor(page, title);
      await expect(chip).toHaveAttribute("data-event-date", isoDate(at));

      await dragTo(chip, cellFor(page, moved));

      // The announcement is the server talking, not the optimistic client move:
      // the hook drops the chip into the new cell before pushing, so asserting
      // only on position would pass even if the push never landed.
      await expect(page.locator('[role="status"]')).toContainText(/^Moved/);
      await expect(chipFor(page, title)).toHaveAttribute("data-event-date", isoDate(moved));

      // And it was written, not just re-rendered.
      await page.reload();
      await expect(chipFor(page, title)).toHaveAttribute("data-event-date", isoDate(moved));
    } finally {
      if (id) await deleteContentById(page, "page", id);
    }
  });

  test("arrow keys move a focused chip by a day", async ({ page }) => {
    const at = scheduleTarget();
    const moved = dayAfter(at);
    const title = `Nudge ${Date.now()}`;
    let id;

    try {
      await signInAsAdmin(page);
      id = await schedulePage(page, { title, slug: `nudge-${Date.now()}`, at });

      await page.goto(`/editor/calendar?at=${isoDate(at)}`);
      const chip = chipFor(page, title);
      await expect(chip).toHaveAttribute("data-event-date", isoDate(at));

      // Focus the link *inside* the chip: the <li> carries the identity (see
      // the markup comment) but the <a> is what a keyboard user actually tabs
      // to, and the hook walks up from there with `closest`. This starts where
      // their focus would really be.
      await chip.getByRole("link").focus();
      await page.keyboard.press("ArrowRight");

      await expect(page.locator('[role="status"]')).toContainText(/^Moved/);
      await expect(chipFor(page, title)).toHaveAttribute("data-event-date", isoDate(moved));

      await page.reload();
      await expect(chipFor(page, title)).toHaveAttribute("data-event-date", isoDate(moved));

      // Back where it started: the inverse key has to be wired too, and a
      // one-directional bug passes every assertion above.
      await chipFor(page, title).getByRole("link").focus();
      await page.keyboard.press("ArrowLeft");
      await expect(chipFor(page, title)).toHaveAttribute("data-event-date", isoDate(at));
    } finally {
      if (id) await deleteContentById(page, "page", id);
    }
  });

  test("a lane that cannot be rescheduled offers no handle", async ({ page }) => {
    const at = scheduleTarget();
    const title = `Handle ${Date.now()}`;
    let id;

    try {
      await signInAsAdmin(page);
      id = await schedulePage(page, { title, slug: `handle-${Date.now()}`, at });

      // The demo seeds ship published content, and "went live" is history —
      // there is nothing to reschedule about a date that has already happened.
      // The server refuses these too (`refuse_undraggable/1`); this is the half
      // that keeps a user from being offered the move at all.
      await page.goto("/editor/calendar");
      const published = page.locator('li[data-event-kind="published"]').first();
      await expect(published).toBeVisible();
      await expect(published).not.toHaveAttribute("data-reschedulable", "true");
      // `cursor-grab` on the link inside is the visual half of the same claim.
      await expect(published.locator(".cursor-grab")).toHaveCount(0);

      // The same two assertions inverted on a lane that *can* move, so the pair
      // above is discriminating rather than just matching a quiet page.
      await page.goto(`/editor/calendar?at=${isoDate(at)}`);
      const chip = chipFor(page, title);
      await expect(chip).toHaveAttribute("data-reschedulable", "true");
      await expect(chip.locator(".cursor-grab")).toHaveCount(1);
    } finally {
      if (id) await deleteContentById(page, "page", id);
    }
  });
});
