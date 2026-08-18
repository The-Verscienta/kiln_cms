// @ts-check
//
// Content list bulk actions (#1314): select several rows on /editor, then
// publish, unpublish and delete them through the two-step confirm bar. The
// LiveView tests cover each verb's handler; this proves the *browser* half —
// that the checkboxes, the toolbar's disabled state, the confirm bar and the
// flash all wire together, and that the list re-renders with the new state.
const {
  test,
  expect,
  signInAsAdmin,
  newDraftPage,
  deleteContentById,
} = require("./fixtures");

// Two drafts whose titles share a unique prefix, so `/editor?q=<prefix>`
// filters the persistent e2e database down to exactly them. Returns their ids
// (captured from the editor URL) so cleanup can find them even if a step
// fails before the title lands.
async function twoDrafts(page, prefix) {
  const ids = [];
  for (const n of [1, 2]) {
    await newDraftPage(page);
    const id = page.url().split("/").pop();
    ids.push(id);
    await page.fill('input[name$="[title]"]', `${prefix} ${n}`);
    await page.fill('input[name$="[slug]"]', `${prefix.toLowerCase().replace(/\s+/g, "-")}-${n}`);
    await page.getByRole("button", { name: /^save$/i }).click();
    // The save round-trips before we navigate away, or the "Untitled" draft
    // is what the list search would (not) find.
    await expect(page.locator('input[name$="[title]"]')).toHaveValue(`${prefix} ${n}`);
  }
  return ids;
}

test.describe("content list bulk actions", () => {
  const prefix = `E2E Bulk ${Date.now()}`;
  /** @type {string[]} */
  let ids = [];

  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Best-effort: the journey's last step deletes both rows itself, so this
    // only matters when it failed part-way. `deleteContentById` is a no-op on
    // a row that is already gone.
    for (const id of ids) await deleteContentById(page, "page", id);
    ids = [];
  });

  test("select all → publish → unpublish → delete, through the confirm bar", async ({ page }) => {
    ids = await twoDrafts(page, prefix);

    await page.goto(`/editor?q=${encodeURIComponent(prefix)}`);
    const rows = page.locator(`li[id^="page-"]`).filter({ hasText: prefix });
    await expect(rows).toHaveCount(2);
    for (const id of ids) await expect(page.locator(`li[id="page-${id}"]`)).toBeVisible();

    // Nothing selected: every verb is disabled, and "None selected" says so.
    const publish = page.locator('button[phx-click="bulk"][phx-value-action="publish"]');
    const unpublish = page.locator('button[phx-click="bulk"][phx-value-action="unpublish"]');
    const del = page.locator('button[phx-click="bulk"][phx-value-action="delete"]');
    await expect(publish).toBeDisabled();
    await expect(del).toBeDisabled();
    await expect(page.getByText("None selected")).toBeVisible();

    // "Select all" selects the *filtered* rows only — two, not the whole site.
    await page.getByLabel("Select all").check();
    await expect(page.getByText("2 selected")).toBeVisible();
    for (const id of ids) {
      await expect(page.locator(`li[id="page-${id}"] input[type="checkbox"]`)).toBeChecked();
    }
    await expect(publish).toBeEnabled();

    // Publish: the confirm bar names the consequence, Cancel backs out without
    // touching anything, and only Confirm acts.
    await publish.click();
    await expect(page.getByText(/Publish 2 selected item\(s\)\? They go live/)).toBeVisible();
    await page.locator('button[phx-click="cancel_bulk"]').click();
    await expect(page.locator('button[phx-click="confirm_bulk"]')).toHaveCount(0);
    for (const id of ids) {
      await expect(page.locator(`li[id="page-${id}"]`).getByText("Draft", { exact: true })).toBeVisible();
    }
    // Cancelling keeps the selection.
    await expect(page.getByText("2 selected")).toBeVisible();

    await publish.click();
    await page.locator('button[phx-click="confirm_bulk"]').click();
    await expect(page.locator("#flash-info")).toContainText("Publish: 2 updated");
    for (const id of ids) {
      await expect(
        page.locator(`li[id="page-${id}"]`).getByText("Published", { exact: true }),
      ).toBeVisible();
    }
    // The selection is cleared after a bulk verb runs.
    await expect(page.getByText("None selected")).toBeVisible();
    await expect(unpublish).toBeDisabled();

    // Unpublish the same two, selecting them individually this time.
    for (const id of ids) {
      await page.locator(`li[id="page-${id}"] input[type="checkbox"]`).check();
    }
    await expect(page.getByText("2 selected")).toBeVisible();
    await unpublish.click();
    await expect(page.getByText(/Unpublish 2 selected item\(s\)\?/)).toBeVisible();
    await page.locator('button[phx-click="confirm_bulk"]').click();
    await expect(page.locator("#flash-info")).toContainText("Unpublish: 2 updated");
    for (const id of ids) {
      await expect(page.locator(`li[id="page-${id}"]`).getByText("Draft", { exact: true })).toBeVisible();
    }

    // Delete (admin-only) is a soft-delete: the rows leave the list, and the
    // flash says "trash", not "gone" — restorable for 30 days.
    await page.getByLabel("Select all").check();
    await del.click();
    await expect(page.getByText(/2 selected item\(s\)/)).toBeVisible();
    await page.locator('button[phx-click="confirm_bulk"]').click();
    await expect(page.locator("#flash-info")).toContainText("Moved 2 item(s) to trash");
    for (const id of ids) await expect(page.locator(`li[id="page-${id}"]`)).toHaveCount(0);

    // Trash still holds them, which is what makes the delete recoverable.
    await page.goto("/editor/trash");
    for (const n of [1, 2]) await expect(page.getByText(`${prefix} ${n}`)).toBeVisible();
    ids = [];
  });
});
