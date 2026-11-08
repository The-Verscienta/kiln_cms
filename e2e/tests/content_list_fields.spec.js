// @ts-check
//
// Custom-field columns in the content list. With one content type chosen,
// /editor offers a "Columns" disclosure; the fields ticked there show as a
// label/value strip on every row and are remembered per user, so a reload
// brings them back. Columns shares the New menu's `data-autoclose` shape
// (app.js closes either when the other, or anything outside, is clicked), and
// ticking a column must not drop a row selection.
//
// The seeds define only page and post, so the spec defines two types of its
// own (one with two string fields) to cross the New menu's threshold, and
// removes everything again afterwards.
const fs = require("node:fs");
const { test, expect, signInAsAdmin, waitForLiveConnected, newDraftContent, saveDraft } = require("./fixtures");

test.describe("content list field columns", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let nameA;
  /** @type {string} */
  let nameB;
  /** @type {string[]} */
  let fieldNames;
  /** @type {string} */
  let title;
  /** @type {string} */
  let draftId;

  /** @param {import("@playwright/test").Page} page @param {string} name */
  async function defineType(page, name) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `Cols ${name}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `Cols ${name}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page.locator("#flash-info")).toContainText("Content type created.");
  }

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    nameA = `e2e_cols_a_${stamp}`;
    nameB = `e2e_cols_b_${stamp}`;
    fieldNames = [`shade_${stamp}`, `origin_${stamp}`];
    title = `Cols Draft ${stamp}`;
    await signInAsAdmin(page);

    await defineType(page, nameA);
    await defineType(page, nameB);

    for (const [index, fieldName] of fieldNames.entries()) {
      await page.goto("/editor/fields");
      await page.locator("#new-field-form").getByRole("checkbox", { name: `Cols ${nameA}`, exact: true }).check();
      await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "string");
      await page.fill('#new-field-form input[name="field_definition[label]"]', index === 0 ? "Shade" : "Origin");
      await page.fill('#new-field-form input[name="field_definition[name]"]', fieldName);
      await page.locator("#new-field-form button[type=submit]").click();
      await expect(page.locator("#flash-info")).toContainText("Field added.");
    }

    draftId = await newDraftContent(page, nameA);
    await page.locator(`#custom-fields #custom-field-${fieldNames[0]}`).fill("Teal");
    await page.locator(`#custom-fields #custom-field-${fieldNames[1]}`).fill("Lisbon");
    await saveDraft(page, { title, slug: `e2e-cols-${stamp}` });
  });

  test.afterEach(async ({ page }) => {
    // Entries first (an archived type's entries drop out of the list), then the
    // fields, then the types, so nothing of this run stays in the persistent
    // e2e database and the seeds' inline "New" buttons come back.
    await page.goto("/editor");
    const rows = page.locator(`li[id^="${nameA}-"]`);
    if (await rows.count()) {
      for (const row of await rows.all()) await row.getByRole("checkbox").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(rows).toHaveCount(0);
    }

    await page.goto("/editor/fields");
    for (const fieldName of fieldNames) {
      const field = page
        .locator('li[id^="field-"]')
        .filter({ has: page.locator(`code:text-is("${fieldName}")`) });
      if (await field.count()) {
        page.once("dialog", dialog => dialog.accept());
        await field.getByRole("button", { name: "Delete field" }).click();
        await expect(field).toHaveCount(0);
      }
    }

    for (const name of [nameA, nameB]) {
      await page.goto("/editor/types");
      const type = page.locator("li[id^='type-']").filter({ hasText: name });
      if (await type.count()) {
        page.once("dialog", dialog => dialog.accept());
        await type.getByRole("button", { name: "Archive content type" }).click();
        await expect(type).toHaveCount(0);
      }
    }
  });

  test("chosen columns show on the row, are remembered across a reload, and keep the selection", async ({
    page,
  }) => {
    await page.goto(`/editor?type=${nameA}`);
    await waitForLiveConnected(page);

    const row = page.locator(`li[id="${nameA}-${draftId}"]`);
    const strip = row.locator("dl");
    await expect(row).toBeVisible();
    await expect(strip).toHaveCount(0);

    // Open the picker and tick Shade: the strip appears on the row.
    await page.locator("#content-columns-toggle").click();
    const panel = page.locator("#content-columns-panel");
    await expect(panel).toBeVisible();
    await panel.getByRole("checkbox", { name: "Shade" }).check();
    await expect(strip).toContainText("Shade");
    await expect(strip).toContainText("Teal");
    await expect(strip).not.toContainText("Origin");

    // A row selection survives a change of columns (a click on the row is an
    // outside click, so the panel is reopened after it), and the panel stays
    // open across the patch that redraws the list.
    await row.getByRole("checkbox").first().check();
    await expect(page.locator("#content-selected-count")).toContainText("1 selected");
    await expect(panel).toBeHidden();
    await page.locator("#content-columns-toggle").click();
    await expect(panel).toBeVisible();
    await panel.getByRole("checkbox", { name: "Origin" }).check();
    await expect(strip).toContainText("Lisbon");
    await expect(page.locator("#content-selected-count")).toContainText("1 selected");
    await expect(panel).toBeVisible();

    // Remembered: a full reload still shows both columns.
    await page.reload();
    await waitForLiveConnected(page);
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toContainText("Teal");
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toContainText("Lisbon");
    await page.locator("#content-columns-toggle").click();
    await expect(page.locator("#content-columns-panel").getByRole("checkbox", { name: "Shade" })).toBeChecked();

    // Untick both and the strip goes.
    await page.locator("#content-columns-panel").getByRole("checkbox", { name: "Shade" }).uncheck();
    await page.locator("#content-columns-panel").getByRole("checkbox", { name: "Origin" }).uncheck();
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toHaveCount(0);
  });

  test("with every type shown there is a hint, not a picker, and no strip", async ({ page }) => {
    await page.goto(`/editor?q=${encodeURIComponent(title)}`);
    await waitForLiveConnected(page);

    await expect(page.locator(`li[id="${nameA}-${draftId}"]`)).toBeVisible();
    await expect(page.locator("#content-columns")).toHaveCount(0);
    await expect(page.locator("#content-columns-hint")).toBeVisible();
    await expect(page.locator(`li[id="${nameA}-${draftId}"] dl`)).toHaveCount(0);
  });

  test("Columns and the New menu close each other, and an outside click closes Columns", async ({ page }) => {
    await page.goto(`/editor?type=${nameA}`);
    await waitForLiveConnected(page);

    const newToggle = page.locator("#content-new-menu-toggle");
    const newPanel = page.locator("#content-new-menu-list");
    const colsToggle = page.locator("#content-columns-toggle");
    const colsPanel = page.locator("#content-columns-panel");

    await newToggle.click();
    await expect(newPanel).toBeVisible();
    await expect(colsPanel).toBeHidden();

    // Opening Columns closes the New menu...
    await colsToggle.click();
    await expect(colsPanel).toBeVisible();
    await expect(colsToggle).toHaveAttribute("aria-expanded", "true");
    await expect(newPanel).toBeHidden();
    await expect(newToggle).toHaveAttribute("aria-expanded", "false");

    // ...and opening the New menu closes Columns.
    await newToggle.click();
    await expect(newPanel).toBeVisible();
    await expect(colsPanel).toBeHidden();
    await expect(colsToggle).toHaveAttribute("aria-expanded", "false");

    // A click outside closes Columns too.
    await colsToggle.click();
    await expect(colsPanel).toBeVisible();
    await page.locator("h1").first().click();
    await expect(colsPanel).toBeHidden();
  });
});

// Filtering and sorting the list by a custom field (#2293). The type, its
// integer field, an API key and 54 entries (more than one page of 50) are all
// this describe's own, written through the JSON:API so the spec does not click
// through 54 editors, and removed again in `finally`-style afterAll cleanup.
test.describe("content list field filter and sort", () => {
  const ROWS = 54;
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let typeName;
  /** @type {string} */
  let fieldName;
  /** @type {number[]} */
  let ranks;

  /** @param {import("@playwright/test").Page} page */
  async function sort(page, value) {
    await page.locator("#content-sort").selectOption(value);
  }

  /** The ranks of the rows on screen, in order (the title carries the rank). */
  async function shownRanks(page) {
    const rows = await page.locator(`li[id^="${typeName}-"]`).allTextContents();
    return rows.map(text => Number(new RegExp(`Flt ${stamp} r(\\d+) n`).exec(text)?.[1]));
  }

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    typeName = `e2e_flt_${stamp}`;
    fieldName = `rank_${stamp}`;
    // Duplicates across the page boundary on purpose: 54 rows, ranks 0..8.
    ranks = Array.from({ length: ROWS }, (_, n) => n % 9);
    await signInAsAdmin(page);

    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `Flt ${typeName}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `Flt ${typeName}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', typeName);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page.locator("#flash-info")).toContainText("Content type created.");

    await page.goto("/editor/fields");
    await page.locator("#new-field-form").getByRole("checkbox", { name: `Flt ${typeName}`, exact: true }).check();
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "integer");
    await page.fill('#new-field-form input[name="field_definition[label]"]', "Rank");
    await page.fill('#new-field-form input[name="field_definition[name]"]', fieldName);
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator("#flash-info")).toContainText("Field added.");

    await page.goto("/editor/api-keys");
    await page.fill('#new-api-key-form input[name="name"]', `e2e-flt-${stamp}`);
    await page.selectOption('#new-api-key-form select[name="access"]', "read_write");
    await page.locator("#new-api-key-form button[type=submit]").click();
    const key = (await page.locator("#new-key-banner code").textContent())?.trim() ?? "";
    expect(key).not.toBe("");

    const headers = {
      authorization: `Bearer ${key}`,
      accept: "application/vnd.api+json",
      "content-type": "application/vnd.api+json",
    };
    const typeRes = await page.request.get(`/api/json/type-definitions/by-name/${typeName}`, { headers });
    expect(typeRes.status(), await typeRes.text()).toBe(200);
    const typeId = (await typeRes.json()).data.id;

    for (const [n, rank] of ranks.entries()) {
      const res = await page.request.post("/api/json/entries", {
        headers,
        data: {
          data: {
            type: "entry",
            attributes: {
              title: `Flt ${stamp} r${rank} n${String(n).padStart(2, "0")}`,
              slug: `e2e-flt-${stamp}-${n}`,
              type_definition_id: typeId,
              custom_fields: { [fieldName]: rank },
            },
          },
        },
      });
      expect(res.status(), await res.text()).toBe(201);
    }
  });

  test.afterEach(async ({ page }) => {
    // Entries first (an archived type's entries drop out of the list), a page
    // of 50 at a time, then the field, then the type.
    await page.goto(`/editor?type=${typeName}`);
    await waitForLiveConnected(page);
    const rows = page.locator(`li[id^="${typeName}-"]`);
    while (await rows.count()) {
      await page.getByLabel("Select all").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(page.locator("#flash-info, #flash-error").first()).toBeVisible();
      await page.goto(`/editor?type=${typeName}`);
      await waitForLiveConnected(page);
    }

    await page.goto("/editor/fields");
    const field = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${fieldName}")`) });
    if (await field.count()) {
      page.once("dialog", dialog => dialog.accept());
      await field.getByRole("button", { name: "Delete field" }).click();
      await expect(field).toHaveCount(0);
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: typeName });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  test("a number condition narrows the list, shows a chip, and survives a reload", async ({ page }) => {
    const expected = ranks.filter(rank => rank >= 7).length;

    await page.goto(`/editor?type=${typeName}`);
    await waitForLiveConnected(page);
    await expect(page.locator("#content-count")).toContainText(`${ROWS} items`);

    await page.locator("#toggle-filters").click();
    await expect(page.locator("#field-filters")).toBeVisible();
    // The value control follows the chosen operator and field.
    await page.locator("#field-filter-op").selectOption("gte");
    await expect(page.locator("#field-filter-value")).toHaveAttribute("type", "number");
    await page.locator("#field-filter-value").fill("7");
    await page.locator("#field-filter-add").click();

    await expect(page.locator("#field-filter-chip-0")).toContainText("Rank ≥ 7");
    await expect(page.locator("#content-count")).toContainText(`${expected} items`);
    await expect(page).toHaveURL(/cf=/);
    expect((await shownRanks(page)).every(rank => rank >= 7)).toBe(true);

    // The URL holds the whole state.
    await page.reload();
    await waitForLiveConnected(page);
    await expect(page.locator("#field-filter-chip-0")).toContainText("Rank ≥ 7");
    await expect(page.locator("#content-count")).toContainText(`${expected} items`);

    // Removing the chip brings every row back.
    await page.locator("#field-filter-chip-0").click();
    await expect(page.locator("#field-filter-chip-0")).toHaveCount(0);
    await expect(page.locator("#content-count")).toContainText(`${ROWS} items`);
  });

  test("a field sort orders across the Load more boundary and survives a reload", async ({ page }) => {
    await page.goto(`/editor?type=${typeName}`);
    await waitForLiveConnected(page);

    await sort(page, `-field:${fieldName}`);
    await expect(page).toHaveURL(/sort=-field/);
    await expect(page.locator(`li[id^="${typeName}-"]`)).toHaveCount(50);
    await page.getByRole("button", { name: "Load more" }).click();
    await expect(page.locator(`li[id^="${typeName}-"]`)).toHaveCount(ROWS);

    const shown = await shownRanks(page);
    expect(shown).toHaveLength(ROWS);
    expect(shown).toEqual([...shown].sort((a, b) => b - a));
    // No row repeated or lost across the boundary.
    expect(new Set(await page.locator(`li[id^="${typeName}-"]`).evaluateAll(els => els.map(e => e.id))).size).toBe(ROWS);

    await page.reload();
    await waitForLiveConnected(page);
    await expect(page.locator("#content-sort")).toHaveValue(`-field:${fieldName}`);
    expect((await shownRanks(page))[0]).toBe(8);

    // Changing another filter keeps the field sort.
    await page.locator("#content-status-filter").selectOption("draft");
    await expect(page).toHaveURL(/sort=-field/);
    await expect(page.locator("#content-sort")).toHaveValue(`-field:${fieldName}`);
  });
});

// Exporting the list (#2293). The type, its integer field, an API key and four
// entries are this describe's own, in ONE test so the entries are written once
// (the API allows 120 writes a minute per address, and the field filter and sort
// describe above already spends ~110 of them); the downloads are read off disk and their
// rows asserted, so the filter and the selection are proven to reach the file.
test.describe("content list export", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let typeName;
  /** @type {string} */
  let fieldName;
  /** Rank per entry, in creation order. */
  const ranks = [1, 5, 5, 9];

  /** @param {import("@playwright/test").Download} download */
  async function csvRows(download) {
    const path = await download.path();
    const text = fs.readFileSync(path, "utf8").replace(/^\uFEFF/, "");
    const [header, ...rows] = text.trim().split(/\r?\n/);
    const columns = header.split(",");
    return rows.map(line => Object.fromEntries(line.split(",").map((value, index) => [columns[index], value])));
  }

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    typeName = `e2e_exp_${stamp}`;
    fieldName = `rank_${stamp}`;
    await signInAsAdmin(page);

    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `Exp ${typeName}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `Exp ${typeName}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', typeName);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page.locator("#flash-info")).toContainText("Content type created.");

    await page.goto("/editor/fields");
    await page.locator("#new-field-form").getByRole("checkbox", { name: `Exp ${typeName}`, exact: true }).check();
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "integer");
    await page.fill('#new-field-form input[name="field_definition[label]"]', "Rank");
    await page.fill('#new-field-form input[name="field_definition[name]"]', fieldName);
    await page.locator("#new-field-form button[type=submit]").click();
    await expect(page.locator("#flash-info")).toContainText("Field added.");

    await page.goto("/editor/api-keys");
    await page.fill('#new-api-key-form input[name="name"]', `e2e-exp-${stamp}`);
    await page.selectOption('#new-api-key-form select[name="access"]', "read_write");
    await page.locator("#new-api-key-form button[type=submit]").click();
    const key = (await page.locator("#new-key-banner code").textContent())?.trim() ?? "";
    expect(key).not.toBe("");

    const headers = {
      authorization: `Bearer ${key}`,
      accept: "application/vnd.api+json",
      "content-type": "application/vnd.api+json",
    };
    const typeRes = await page.request.get(`/api/json/type-definitions/by-name/${typeName}`, { headers });
    expect(typeRes.status(), await typeRes.text()).toBe(200);
    const typeId = (await typeRes.json()).data.id;

    for (const [n, rank] of ranks.entries()) {
      const res = await page.request.post("/api/json/entries", {
        headers,
        data: {
          data: {
            type: "entry",
            attributes: {
              title: `Exp ${stamp} r${rank} n${n}`,
              slug: `e2e-exp-${stamp}-${n}`,
              type_definition_id: typeId,
              custom_fields: { [fieldName]: rank },
            },
          },
        },
      });
      expect(res.status(), await res.text()).toBe(201);
    }
  });

  test.afterEach(async ({ page }) => {
    await page.goto(`/editor?type=${typeName}`);
    await waitForLiveConnected(page);
    const rows = page.locator(`li[id^="${typeName}-"]`);
    while (await rows.count()) {
      await page.getByLabel("Select all").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(page.locator("#flash-info, #flash-error").first()).toBeVisible();
      await page.goto(`/editor?type=${typeName}`);
      await waitForLiveConnected(page);
    }

    await page.goto("/editor/fields");
    const field = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${fieldName}")`) });
    if (await field.count()) {
      page.once("dialog", dialog => dialog.accept());
      await field.getByRole("button", { name: "Delete field" }).click();
      await expect(field).toHaveCount(0);
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: typeName });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  test("a CSV honours a field filter and a column; Export selected sends only the selected ids", async ({
    page,
  }) => {
    await page.goto(`/editor?type=${typeName}`);
    await waitForLiveConnected(page);

    // The saved list columns are what the export's field columns are.
    await page.locator("#content-columns-toggle").click();
    await page.locator("#content-columns-panel").getByRole("checkbox", { name: "Rank" }).check();

    await page.locator("#toggle-filters").click();
    await page.locator("#field-filter-op").selectOption("gte");
    await page.locator("#field-filter-value").fill("5");
    await page.locator("#field-filter-add").click();
    await expect(page.locator("#field-filter-chip-0")).toContainText("Rank ≥ 5");

    await page.locator("#content-export-toggle").click();
    await expect(page.locator("#export-summary")).toContainText(`Export ${ranks.filter(rank => rank >= 5).length} matching`);

    const [download] = await Promise.all([page.waitForEvent("download"), page.locator("#export-csv").click()]);
    expect(download.suggestedFilename()).toMatch(/\.csv$/);

    const rows = await csvRows(download);
    expect(rows).toHaveLength(ranks.filter(rank => rank >= 5).length);
    expect(rows.every(row => Number(row[fieldName]) >= 5)).toBe(true);
    expect(rows.every(row => row.title.startsWith(`Exp ${stamp} `))).toBe(true);

    // Export selected: back to the whole list, two rows ticked.
    await page.locator("#field-filter-chip-0").click();
    await expect(page.locator("#field-filter-chip-0")).toHaveCount(0);

    const listed = page.locator(`li[id^="${typeName}-"]`);
    await expect(listed).toHaveCount(ranks.length);
    const picked = [await listed.nth(0).getAttribute("id"), await listed.nth(2).getAttribute("id")];
    const pickedIds = picked.map(id => String(id).slice(typeName.length + 1));

    await listed.nth(0).getByRole("checkbox").first().check();
    await listed.nth(2).getByRole("checkbox").first().check();
    await expect(page.locator("#content-selected-count")).toContainText("2 selected");

    const [selectedDownload] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#bulk-export-selected").click(),
    ]);
    const selectedRows = await csvRows(selectedDownload);

    expect(selectedRows.map(row => row.id).sort()).toEqual([...pickedIds].sort());
  });
});
