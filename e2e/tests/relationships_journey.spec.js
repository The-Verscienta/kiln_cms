// @ts-check
//
// The relationships plan end to end (docs/relationships-plan.md, R0–R10), the
// way a non-developer meets it: a recipe → ingredient many-to-many modelled
// in the fields admin, filled from both ends, held to its limits, and then
// read and written through every API. Each workstream has its own tests;
// this one walks them together, in one browser session, on one field.
//
// The journey is one test because every step builds on the last (the field,
// then the records, then the connections the APIs read back).
const { test, expect, signInAsAdmin, newDraftContent, saveDraft } = require("./fixtures");

test.describe("relationships journey", () => {
  test.setTimeout(240_000);

  /** @type {string} */
  let stamp;
  /** @type {{recipe: string, ingredient: string, spice: string}} */
  let types;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    types = { recipe: `e2e_rec_${stamp}`, ingredient: `e2e_ing_${stamp}`, spice: `e2e_spi_${stamp}` };
    await signInAsAdmin(page);
  });

  test.afterEach(async ({ page }) => {
    // Entries, then the types (archiving a type with a field still pointing
    // at it is fine; the field goes with its type).
    await page.goto(`/editor?q=${stamp}`);
    const rows = page.locator("li[id]").filter({ hasText: stamp }).filter({ has: page.getByRole("checkbox") });
    if (await rows.count()) {
      for (const row of await rows.all()) await row.getByRole("checkbox").check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();
      await expect(rows).toHaveCount(0);
    }

    await page.goto("/editor/types");
    for (const name of Object.values(types)) {
      const type = page.locator("li[id^='type-']").filter({ hasText: name });
      if (await type.count()) {
        page.once("dialog", dialog => dialog.accept());
        await type.getByRole("button", { name: "Archive content type" }).click();
        await expect(type).toHaveCount(0);
      }
    }
  });

  /** @param {import("@playwright/test").Page} page @param {string} label @param {string} name */
  async function createType(page, label, name) {
    await page.goto("/editor/types");
    await page.fill('#new-type-form input[name="type_definition[label]"]', `${label} ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[plural_label]"]', `${label}s ${stamp}`);
    await page.fill('#new-type-form input[name="type_definition[name]"]', name);
    await page.locator("#new-type-form").getByRole("button", { name: "Create content type" }).click();
    await expect(page).toHaveURL(/\/editor\/fields\?type=def/);
    return page.url();
  }

  /** A draft entry of `type` titled `title`; returns its id. */
  async function entry(page, type, title) {
    const id = await newDraftContent(page, type);
    await saveDraft(page, { title: `${title} ${stamp}`, slug: `${title.toLowerCase()}-${stamp}` });
    return id;
  }

  async function publish(page) {
    await page.getByRole("button", { name: /^publish now$/i }).click();
    await expect(page.getByRole("button", { name: /^unpublish$/i })).toBeVisible();
  }

  /** Pick the one search result for `query` in the picker rooted at `root`. */
  async function pick(page, root, query) {
    const search = page.locator(`#${root}-search`);
    await search.click();
    await search.fill("");
    await search.pressSequentially(query);
    const option = page.locator(`#${root}-listbox`).getByRole("option").filter({ hasText: query });
    await expect(option).toHaveCount(1);
    await option.click();
  }

  test("model a recipe → ingredient many-to-many, fill it from both ends, read and write it over the APIs", async ({
    page,
  }) => {
    const ids = {};
    /** @type {string} */
    let fieldsUrl = "";

    await test.step("fields admin: several target types, multiple, inverse, cap, delete rule", async () => {
      await createType(page, "Ingredient", types.ingredient);
      await createType(page, "Spice", types.spice);
      fieldsUrl = await createType(page, "Recipe", types.recipe);

      await page.goto(fieldsUrl);
      const form = page.locator("#new-field-form");
      await form.locator('input[name="field_definition[label]"]').fill("Ingredients");
      await form.locator('input[name="field_definition[name]"]').fill("ingredients");
      await form.locator('select[name="field_definition[field_type]"]').selectOption("reference");
      await page.locator(`#new-field-targets-${types.ingredient}`).check();
      await page.locator(`#new-field-targets-${types.spice}`).check();
      await page.locator("#new-field-multiple-true").check();
      await form.locator('input[name="field_definition[inverse_label]"]').fill("Used in recipes");
      await form.locator('input[name="field_definition[max_sources]"]').fill("2");
      await page.locator("#new-field-rules-delete-restrict").check();
      await form.locator("button[type=submit]").click();

      const field = page
        .locator('li[id^="field-"]')
        .filter({ has: page.locator('code:text-is("ingredients")') })
        // Other runs' archived recipe types list an `ingredients` field too.
        .filter({ hasText: `Ingredient ${stamp}` });
      await expect(field).toContainText("Connects several");
      await expect(field).toContainText("Used in recipes");
      await expect(field).toContainText("at most 2 records");
      await expect(field).toContainText("can't be deleted for good");

      // Details on each connection: a whole-number quantity and a role.
      for (const [label, type] of [["Quantity", "integer"], ["Role", "string"]]) {
        await field.locator('button[phx-click="link_new"]').click();
        const linkForm = page.locator('form[id^="link-field-form-new-"]');
        await linkForm.locator('input[name="link_field[label]"]').fill(label);
        await linkForm.locator('select[name="link_field[field_type]"]').selectOption(type);
        await linkForm.locator("button[type=submit]").click();
        await expect(field.locator('li[id^="link-field-"]').filter({ hasText: label })).toBeVisible();
      }
    });

    await test.step("records: ingredients and a spice, published", async () => {
      ids.flour = await entry(page, types.ingredient, "Flour");
      await publish(page);
      ids.sugar = await entry(page, types.ingredient, "Sugar");
      await publish(page);
      ids.salt = await entry(page, types.spice, "Salt");
      await publish(page);
    });

    await test.step("source side: connect two types with link data, save, publish", async () => {
      ids.cake = await entry(page, types.recipe, "Cake");
      const root = "custom-field-ingredients";
      await pick(page, root, `Flour ${stamp}`);
      await pick(page, root, `Salt ${stamp}`);
      const rows = page.locator(`#${root}-items > li`);
      await expect(rows).toHaveCount(2);
      await rows.nth(0).locator('input[name$="[quantity]"]').fill("500");
      await rows.nth(0).locator('input[name$="[role]"]').fill("main");
      await saveDraft(page, { title: `Cake ${stamp}` });
      await page.reload();
      await expect(rows).toHaveCount(2);
      await expect(rows.nth(0).locator('input[name$="[quantity]"]')).toHaveValue("500");
      await publish(page);

      ids.bread = await entry(page, types.recipe, "Bread");
      await publish(page);
      ids.cookie = await entry(page, types.recipe, "Cookie");
    });

    const reverse = `reverse-field-${types.recipe}-ingredients`;

    await test.step("target side (R4/R4b): reverse list, connect a published and a draft source, cap", async () => {
      await page.goto(`/editor/content/${types.ingredient}/${ids.flour}`);
      const list = page.locator(`#${reverse}`);
      await expect(list).toContainText("Used in recipes");
      await expect(page.locator(`#${reverse}-capacity`)).toHaveText("1 of 2");
      await expect(page.locator(`#${reverse}-${ids.cake}`)).toContainText(`Cake ${stamp}`);
      await expect(page.locator(`#${reverse}-${ids.cake}-details`)).toContainText("500");

      // A published source: the connection waits in its working copy.
      await pick(page, `custom-field-reverse-${types.recipe}-ingredients`, `Bread ${stamp}`);
      await expect(page.locator(`#${reverse}-${ids.bread}-pending`)).toBeVisible();
      // Pending connections hold no slot yet.
      await expect(page.locator(`#${reverse}-capacity`)).toHaveText("1 of 2");

      // A draft source: written live, and the target is now full.
      await pick(page, `custom-field-reverse-${types.recipe}-ingredients`, `Cookie ${stamp}`);
      await expect(page.locator(`#${reverse}-${ids.cookie}`)).toBeVisible();
      await expect(page.locator(`#${reverse}-capacity`)).toHaveText("2 of 2");
      await expect(page.locator(`#${reverse}-full`)).toContainText("Full — 2 of 2");
    });

    await test.step("cap at publish: Bread's held connection to the full Flour is refused", async () => {
      await page.goto(`/editor/content/${types.recipe}/${ids.bread}`);
      await page.locator("#publish-changes").click();
      const confirm = page.getByRole("button", { name: /^publish changes$/i }).last();
      if (await confirm.isVisible()) await confirm.click();
      await expect(page.locator("#flash-error")).toContainText(`“Flour ${stamp}” is full`);
    });

    await test.step("source-side picker shows the full target as full", async () => {
      // Bread's working copy still holds Flour (so its picker leaves Flour
      // out); a fresh recipe sees Flour listed, and disabled.
      ids.pie = await entry(page, types.recipe, "Pie");
      const search = page.locator("#custom-field-ingredients-search");
      await search.click();
      await search.pressSequentially(`Flour ${stamp}`);
      await expect(page.locator("#custom-field-ingredients-listbox")).toContainText("Full — 2 of 2");
    });

    await test.step("R5: purge under :restrict is refused; under :clear it unlinks", async () => {
      await page.goto(`/editor?q=Salt ${stamp}`);
      await page.getByRole("checkbox", { name: `Select Salt ${stamp}`, exact: true }).check();
      await page.locator('button[phx-click="bulk"][phx-value-action="delete"]').click();
      await page.locator('button[phx-click="confirm_bulk"]').click();

      await page.goto("/editor/trash");
      const trashed = page.locator(`#trash-${types.spice}-${ids.salt}`);
      await expect(trashed).toBeVisible();
      page.once("dialog", dialog => dialog.accept());
      await trashed.locator('button[phx-click="purge"]').click();
      await expect(page.locator("#flash-error")).toContainText("Ingredients");
      await expect(trashed).toBeVisible();

      // Switch the field to "Remove it from them" and purge again.
      await page.goto(fieldsUrl);
      const field = page
        .locator('li[id^="field-"]')
        .filter({ has: page.locator('code:text-is("ingredients")') })
        // Other runs' archived recipe types list an `ingredients` field too.
        .filter({ hasText: `Ingredient ${stamp}` });
      await field.locator('button[phx-click="edit"]').click();
      await page.locator('[id^="edit-field-rules-"][id$="-delete-clear"]').check();
      await page.locator('form[id^="edit-field-"] button[type=submit]').click();
      await expect(field).toContainText("are removed from the records");

      await page.goto("/editor/trash");
      page.once("dialog", dialog => dialog.accept());
      await trashed.locator('button[phx-click="purge"]').click();
      await expect(trashed).toHaveCount(0);

      await page.goto(`/editor/content/${types.recipe}/${ids.cake}`);
      await expect(page.locator("#custom-field-ingredients-items > li")).toHaveCount(1);
    });

    /** @type {string} */
    let key;
    await test.step("an API key, minted in the admin", async () => {
      await page.goto("/editor/api-keys");
      await page.fill('#new-api-key-form input[name="name"]', `e2e-rel-${stamp}`);
      await page.selectOption('#new-api-key-form select[name="access"]', "read_write");
      await page.locator("#new-api-key-form button[type=submit]").click();
      key = (await page.locator("#new-key-banner code").textContent())?.trim() ?? "";
      expect(key).not.toBe("");
    });

    const api = (path, opts = {}) =>
      page.request.fetch(path, {
        ...opts,
        headers: { authorization: `Bearer ${key}`, accept: "application/vnd.api+json", ...(opts.headers || {}) },
      });

    await test.step("JSON:API custom_filter has / count / link", async () => {
      const titles = async query => {
        const res = await api(`/api/json/entries?filter[type_name]=${types.recipe}&${query}&fields[entry]=title`);
        expect(res.status(), await res.text()).toBe(200);
        return (await res.json()).data.map(d => d.attributes.title).sort();
      };
      expect(await titles(`custom_filter[ingredients][has][]=${ids.flour}`)).toEqual([
        `Cake ${stamp}`,
        `Cookie ${stamp}`,
      ]);
      expect(await titles(`custom_filter[ingredients][has_none]=${ids.flour}`)).toEqual([
        `Bread ${stamp}`,
        `Pie ${stamp}`,
      ]);
      expect(await titles(`custom_filter[ingredients][count][gte]=1`)).toEqual([`Cake ${stamp}`, `Cookie ${stamp}`]);
      expect(await titles(`custom_filter[ingredients.link.role]=main`)).toEqual([`Cake ${stamp}`]);
      expect(await titles(`custom_filter[ingredients.link.quantity][gte]=100`)).toEqual([`Cake ${stamp}`]);
    });

    await test.step("delivery ?expand=", async () => {
      const res = await page.request.get(`/api/content/${types.recipe}/cake-${stamp}?expand=ingredients`);
      expect(res.status(), await res.text()).toBe(200);
      const body = await res.json();
      const expanded = body.expanded.ingredients;
      expect(expanded).toHaveLength(1);
      expect(expanded[0].id).toBe(ids.flour);
      expect(expanded[0].link).toEqual({ quantity: 500, role: "main" });
      expect(JSON.stringify(expanded[0].target)).toContain(`Flour ${stamp}`);
    });

    const gql = async (query, variables = {}) => {
      const res = await page.request.post("/gql", {
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        data: { query, variables },
      });
      expect(res.status(), await res.text()).toBe(200);
      const body = await res.json();
      expect(body.errors, JSON.stringify(body.errors)).toBeUndefined();
      return body.data;
    };

    // `customFields` is a JSON string scalar; `link` is a JSON object.
    const json = value => (typeof value === "string" ? JSON.parse(value) : value);

    await test.step("GraphQL references / referencedBy", async () => {
      const data = await gql(
        `query($slug: String!, $flour: String!) {
          cake: publishedEntries(filter: {slug: {eq: $slug}}, limit: 1) { results {
            references(field: "ingredients", limit: 10) { position link target { id title } } } }
          flour: publishedEntries(filter: {slug: {eq: $flour}}, limit: 1) { results {
            referencedBy(inverse: "used_in_recipes", limit: 10) { field position source { title } } } }
        }`,
        { slug: `cake-${stamp}`, flour: `flour-${stamp}` },
      );
      const refs = data.cake.results[0].references;
      expect(refs.map(r => r.target.title)).toEqual([`Flour ${stamp}`]);
      expect(refs[0].link).toEqual({ quantity: 500, role: "main" });
      // The key acts as an admin, who may read the draft Cookie too.
      const by = data.flour.results[0].referencedBy.map(r => r.source.title).sort();
      expect(by).toEqual([`Cake ${stamp}`, `Cookie ${stamp}`]);
    });

    await test.step("GraphQL addEntryReferences / moveEntryReference", async () => {
      const added = await gql(
        `mutation($id: ID!, $sugar: ID!, $type: String!) {
          addEntryReferences(id: $id, field: "ingredients",
            targets: [{id: $sugar, type: $type, link: "{\\"quantity\\": 3}"}], position: {start: true}) {
            result { customFields } errors { message }
          }
        }`,
        { id: ids.cookie, sugar: ids.sugar, type: types.ingredient },
      );
      expect(added.addEntryReferences.errors).toEqual([]);
      let order = json(added.addEntryReferences.result.customFields).ingredients.map(i => i.id);
      expect(order).toEqual([ids.sugar, ids.flour]);

      const moved = await gql(
        `mutation($id: ID!, $sugar: ID!, $flour: ID!) {
          moveEntryReference(id: $id, field: "ingredients", target: $sugar, position: {after: $flour}) {
            result { customFields } errors { message }
          }
        }`,
        { id: ids.cookie, sugar: ids.sugar, flour: ids.flour },
      );
      expect(moved.moveEntryReference.errors).toEqual([]);
      order = json(moved.moveEntryReference.result.customFields).ingredients.map(i => i.id);
      expect(order).toEqual([ids.flour, ids.sugar]);

      // The cap holds over the API too: Flour is full (Cake, Cookie).
      const refused = await gql(
        `mutation($id: ID!, $flour: ID!, $type: String!) {
          addEntryReferences(id: $id, field: "ingredients", targets: [{id: $flour, type: $type}]) {
            result { id } errors { message }
          }
        }`,
        { id: ids.bread, flour: ids.flour, type: types.ingredient },
      );
      expect(refused.addEntryReferences.result).toBeNull();
      expect(JSON.stringify(refused.addEntryReferences.errors)).toContain("is full");
    });
  });
});
