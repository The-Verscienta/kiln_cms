// @ts-check
//
// A `:flexible` field's item cards in the content editor (#2282, PR 2): an
// item added from the "Add item" menu, typed into, a setting filled in a
// collapsed Settings section, items reordered with the move buttons, a card
// collapsed (and still collapsed after LiveView patches the form), an item
// duplicated and removed, a card of a nested list dragged by its own handle
// (the outer list untouched), then saved and reloaded.
//
// A second journey (PR 3): an image and a record picked inside an item card
// (the media drawer and the record search each address the card by its `_id`
// chain), saved and shown again after a reload.
//
// `FlexibleEditorTest` pushes the events itself. It proves what the server
// does with an `_id` path, and nothing about whether a click or a drag
// produces one, whether a collapsed card survives a patch, or whether a
// setting nobody can see still posts.
const { test, expect, signInAsAdmin, newDraftContent, newDraftPage, saveDraft, holdsAcross } = require("./fixtures");

// A minimal valid 1x1 PNG (the same bytes the Elixir tests upload).
const PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP6zwAAAAcAAQL+pTXmAAAAAElFTkSuQmCC";

test.describe("flexible field items", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let name;
  /** @type {string} */
  let field;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    name = `e2e_flex_${stamp}`;
    field = `${name}_sections`;
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    for (const kind of [name, "page"]) {
      await page.goto("/editor");
      const rows = page.locator(`li[id^="${kind}-"]`).filter({ hasText: stamp });
      if (await rows.count()) {
        for (const row of await rows.all()) await row.getByRole("checkbox").check();
        await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
        await page.locator('button[phx-click="confirm_bulk"]').click();
        await expect(rows).toHaveCount(0);
      }
    }

    await page.goto("/editor/fields");
    const top = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${field}")`) });
    if (await top.count()) {
      await top.first().getByRole("button", { name: "Delete field", exact: true }).click();
      await page.locator('[id^="item-delete-"][id$="-confirm"]').click();
      await expect(top).toHaveCount(0);
    }

    await page.goto("/editor/types");
    const type = page.locator("li[id^='type-']").filter({ hasText: name });
    if (await type.count()) {
      page.once("dialog", dialog => dialog.accept());
      await type.getByRole("button", { name: "Archive content type" }).click();
      await expect(type).toHaveCount(0);
    }
  });

  /**
   * Add a sub-field ("Fields in each item") to an item type or nested field
   * row, by its panel's "Add a field" button.
   * @param {import("@playwright/test").Locator} scope
   * @param {string} label
   * @param {string} type
   * @param {{ setting?: boolean, targets?: string[] }} [opts]
   */
  async function addSubField(scope, label, type, opts = {}) {
    await scope.getByRole("button", { name: "Add a field" }).first().click();
    const form = scope.locator('form[id^="link-field-form-new-"]').first();
    await form.locator('input[name="link_field[label]"]').fill(label);
    await form.locator('select[name="link_field[field_type]"]').selectOption(type);
    if (opts.setting) await form.locator('input[type=checkbox][name="link_field[item_setting]"]').check();
    for (const target of opts.targets || [])
      await form.locator(`input[type=checkbox][name="link_field[target_types][]"][value="${target}"]`).check();
    await form.getByRole("button", { name: "Save field" }).click();
    await expect(scope.locator(`code:text-is("${label.toLowerCase()}")`).first()).toBeVisible();
  }

  /** @param {import("@playwright/test").Locator} scope @param {string} label */
  async function addItemType(scope, label) {
    await scope.getByRole("button", { name: "Add an item type" }).first().click();
    const form = scope.locator('form[id^="item-type-form-new-"]').first();
    await form.locator('input[name="item_type[label]"]').fill(label);
    await form.getByRole("button", { name: "Save item type" }).click();
    await expect(scope.locator(`li[id^="item-type-"]`).filter({ hasText: label }).first()).toBeVisible();
  }

  /** A type with a flexible field: hero (headline + a setting), columns (a nested list of cells). @param {import("@playwright/test").Page} page */
  async function createType(page, { media = false } = {}) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `E2E Flex ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `E2E Flex ${stamp}s`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);

    await page.fill('#new-field-form input[name="field_definition[label]"]', "Sections");
    await page.fill('#new-field-form input[name="field_definition[name]"]', field);
    await page.selectOption('#new-field-form select[name="field_definition[field_type]"]', "flexible");
    await page.locator("#new-field-form button[type=submit]").click();

    const top = page.locator('li[id^="field-"]').filter({ has: page.locator(`code:text-is("${field}")`) });
    await expect(top).toBeVisible();

    const types = top.locator('div[id$="-item-types"]').first();
    await addItemType(types, "Hero");
    await addItemType(types, "Columns");

    const hero = types.locator("li[id^='item-type-']").filter({ hasText: "Hero" }).first();
    await addSubField(hero, "Headline", "string");
    await addSubField(hero, "Accent", "string", { setting: true });
    if (media) {
      await addSubField(hero, "Picture", "media");
      await addSubField(hero, "Link", "reference", { targets: ["page"] });
    }

    const columns = types.locator("li[id^='item-type-']").filter({ hasText: "Columns" }).first();
    await addSubField(columns, "Cells", "flexible");

    const cells = columns.locator('li[id^="link-field-"]').filter({ has: page.locator('code:text-is("cells")') }).first();
    await addItemType(cells, "Cell");
    const cell = cells.locator("li[id^='item-type-']").filter({ hasText: "Cell" }).first();
    await addSubField(cell, "Label", "string");
  }

  /** @param {import("@playwright/test").Page} page @param {string} type */
  async function addItem(page, type) {
    await page.locator(`#custom-field-${field}-add`).click();
    await page.locator(`#custom-field-${field}-add-${type}`).click();
    // The menu closes itself.
    await expect(page.locator(`#custom-field-${field}-add-menu`)).toBeHidden();
  }

  test("add, fill, reorder, collapse, duplicate, drag a nested card, save and reload", async ({ page }) => {
    await createType(page);
    await newDraftContent(page, name);

    const cards = page.locator(`#custom-field-${field}-items > li`);
    const headlines = () =>
      cards.locator('input[name$="[headline]"]').evaluateAll(els => els.map(el => /** @type {HTMLInputElement} */ (el).value));

    // Add: the menu lists the types; the card arrives expanded, after the others.
    await addItem(page, "hero");
    await addItem(page, "hero");
    await expect(cards).toHaveCount(2);
    await cards.nth(0).locator('input[name$="[headline]"]').fill("first");
    await cards.nth(1).locator('input[name$="[headline]"]').fill("second");
    await expect(cards.nth(0)).toContainText("first");

    // A setting in the collapsed Settings section posts like any other value.
    const settings = cards.nth(0).locator(".flex-settings");
    await expect(settings.locator("input[name$='[_settings][accent]']")).toBeHidden();
    await settings.getByRole("button", { name: "Settings" }).click();
    await settings.locator("input[name$='[_settings][accent]']").fill("teal");

    // Reorder with the move buttons.
    await cards.nth(1).getByRole("button", { name: "Move item 2 up" }).click();
    await expect.poll(headlines).toEqual(["second", "first"]);
    await expect(cards.nth(1).locator("input[name$='[_settings][accent]']")).toHaveValue("teal");

    // Collapse a card: its body goes, its header stays, and a patch (typing
    // elsewhere on the form) does not open it again.
    const second = cards.nth(0);
    await second.locator('[id$="-toggle"]').first().click();
    await expect(second.locator(".flex-card-body").first()).toBeHidden();
    await expect(second.locator('[id$="-toggle"]').first()).toHaveAttribute("aria-expanded", "false");
    await cards.nth(1).locator('input[name$="[headline]"]').fill("first!");
    await holdsAcross(page, () => second.locator(".flex-card-body").first().isHidden(), true);
    // The collapsed card still posts what it holds.
    await expect(second.locator('input[name$="[headline]"]')).toHaveValue("second");
    // A card that holds an error opens whatever was collapsed (the server
    // renders `data-errors`; the CSS rule, not a patch, decides).
    await second.evaluate(el => el.setAttribute("data-errors", "true"));
    await expect(second.locator(".flex-card-body").first()).toBeVisible();
    await second.evaluate(el => el.setAttribute("data-errors", "false"));
    await expect(second.locator(".flex-card-body").first()).toBeHidden();

    // Duplicate "first!", then remove the copy.
    await cards.nth(1).getByRole("button", { name: "Duplicate item 2" }).click();
    await expect(cards).toHaveCount(3);
    await expect.poll(headlines).toEqual(["second", "first!", "first!"]);
    await cards.nth(2).getByRole("button", { name: "Remove item 3" }).click();
    await expect(cards).toHaveCount(2);

    // A nested list: two cells, the second dragged above the first by its own
    // handle. The outer list keeps its order.
    await addItem(page, "columns");
    await expect(cards).toHaveCount(3);
    const columns = cards.nth(2);
    const cellAdd = columns.locator('[id$="-cells-add"]').first();
    for (const label of ["a", "b"]) {
      await cellAdd.click();
      await columns.locator('[id$="-cells-add-cell"]').click();
      const count = label === "a" ? 1 : 2;
      await expect(columns.locator('[id$="-cells-items"] > li')).toHaveCount(count);
      await columns.locator('[id$="-cells-items"] > li').last().locator('input[name$="[label]"]').fill(label);
    }

    const cells = columns.locator('[id$="-cells-items"] > li');
    const labels = () => cells.locator('input[name$="[label]"]').evaluateAll(els => els.map(el => /** @type {HTMLInputElement} */ (el).value));
    await expect.poll(labels).toEqual(["a", "b"]);

    await cells.nth(1).locator("[data-flex-handle]").dragTo(cells.nth(0), { targetPosition: { x: 20, y: 4 } });
    await expect.poll(labels).toEqual(["b", "a"]);
    await expect.poll(headlines).toEqual(["second", "first!"]);

    await saveDraft(page, { title: `Flex ${stamp}`, slug: `flex-${stamp}` });
    await page.reload();

    await expect(cards).toHaveCount(3);
    await expect.poll(headlines).toEqual(["second", "first!"]);
    await expect(cards.nth(1).locator("input[name$='[_settings][accent]']")).toHaveValue("teal");
    await expect.poll(labels).toEqual(["b", "a"]);
  });
  test("an image and a record picked inside an item are saved and shown again", async ({ page }) => {
    await createType(page, { media: true });

    // The record to link to: a page with a title the search can find.
    await newDraftPage(page);
    await saveDraft(page, { title: `Target ${stamp}`, slug: `target-${stamp}` });

    await newDraftContent(page, name);
    await addItem(page, "hero");
    await addItem(page, "hero");
    const cards = page.locator(`#custom-field-${field}-items > li`);
    await expect(cards).toHaveCount(2);
    const second = cards.nth(1);

    // The image: the drawer opens from the card, the upload lands in that
    // card only.
    await second.getByRole("button", { name: /^Choose .* for item \d+ in / }).click();
    const drawer = page.locator("#image-picker-dialog");
    await expect(drawer).toBeVisible();
    await drawer.locator('input[type="file"]').setInputFiles({
      name: `item-${stamp}.png`,
      mimeType: "image/png",
      buffer: Buffer.from(PNG_BASE64, "base64"),
    });
    await expect(drawer).toBeHidden();
    await expect(second.locator('input[type="hidden"][name$="[picture]"]')).toHaveValue(/.+/);
    await expect(second.locator('img[src*="/uploads/"]')).toBeVisible();
    await expect(cards.nth(0).locator('input[type="hidden"][name$="[picture]"]')).toHaveValue("");
    await expect(cards.nth(0).getByRole("button", { name: /^Choose .* for item \d+ in / })).toBeVisible();

    // The record: the search sits in the card, under an id of its own.
    const search = second.locator("input[data-ref-search]");
    await search.click();
    await search.fill(`Target ${stamp}`);
    await page.locator(`[role="option"]`).filter({ hasText: `Target ${stamp}` }).first().click();
    await expect(second.locator('input[type="hidden"][name$="[link]"]')).toHaveValue(/.+/);
    await expect(second).toContainText(`Target ${stamp}`);
    await expect(cards.nth(0).locator('input[type="hidden"][name$="[link]"]')).toHaveValue("");

    await cards.nth(0).locator('input[name$="[headline]"]').fill("plain");
    await second.locator('input[name$="[headline]"]').fill("pictured");
    await saveDraft(page, { title: `Flex pics ${stamp}`, slug: `flex-pics-${stamp}` });
    await page.reload();

    const again = page.locator(`#custom-field-${field}-items > li`);
    await expect(again).toHaveCount(2);
    await expect(again.nth(1).locator('img[src*="/uploads/"]')).toBeVisible();
    await expect(again.nth(1)).toContainText(`Target ${stamp}`);
    await expect(again.nth(1).locator('input[type="hidden"][name$="[picture]"]')).toHaveValue(/.+/);
    await expect(again.nth(0).locator('input[type="hidden"][name$="[picture]"]')).toHaveValue("");

    // Remove the image: the card forgets it, the other card is untouched.
    await again.nth(1).getByRole("button", { name: /^Remove .* of item \d+ in / }).click();
    await expect(again.nth(1).locator('input[type="hidden"][name$="[picture]"]')).toHaveValue("");
  });
});
