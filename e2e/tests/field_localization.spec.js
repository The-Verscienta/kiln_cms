// @ts-check
//
// Field-level localization (#1327, #1856; translation-write refusal #1896)
// end to end: a page field set to *Shared* on /editor/fields is read-only on
// a translation and follows the source when it publishes; a *fallback* field
// left empty on a translation shows the source's value as its placeholder, and
// delivery serves the inherited value. `ContentEditorLocalizationTest` renders
// the same notes through LiveViewTest, which runs none of the hooks around
// them and never runs `KilnCMS.I18n.SharedFieldsWorker`, the Oban job that
// copies a shared value into a translation after the source publishes.
//
// The e2e site has one locale, and specs such as status_marks.spec.js count on
// it. This spec adds `fr` for itself through the e2e-only `/dev/e2e-locales`
// route (KilnCMSWeb.Plugs.E2ELocales) and puts the old list back afterwards.
// With no chain configured for `fr`, `KilnCMS.I18n.Fallback` falls back to the
// default locale, so the chain is `fr → en`. The setting is VM-global; the
// suite's `workers: 1` keeps it to this spec.
//
// Oban runs every queue in the e2e env (config/e2e.exs), so the worker runs
// for real on `:firing`. The spec reloads until its result shows.
const { test, expect, signInAsAdmin, newDraftPage, saveDraft, save, deleteContentById } = require("./fixtures");

// Set the deployment's locales, returning the list it had. Sent from a
// signed-in page, which carries the CSRF token the dev-tools scope's
// `protect_from_forgery` asks for.
/** @param {import("@playwright/test").Page} page @param {string[]} locales */
async function setLocales(page, locales) {
  const reply = await page.evaluate(async locales => {
    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content");
    const res = await fetch("/dev/e2e-locales", {
      method: "POST",
      headers: { "content-type": "application/json", "x-csrf-token": token || "" },
      body: JSON.stringify({ locales }),
    });
    return { status: res.status, body: await res.json() };
  }, locales);
  expect(reply.status).toBe(200);
  expect(reply.body.locales).toEqual(locales);
  return reply.body.was;
}

// A page custom field from /editor/fields, with its *Across locales* mode.
/** @param {import("@playwright/test").Page} page @param {string} name @param {string} mode */
async function createPageField(page, name, mode) {
  await page.goto("/editor/fields?type=page");
  const form = page.locator("#new-field-form");
  await expect(form.locator('input[name="field_definition[scopes][]"][value="page"]')).toBeChecked();
  await form.locator('input[name="field_definition[label]"]').fill(name);
  await form.locator('input[name="field_definition[name]"]').fill(name);
  await form.locator('select[name="field_definition[localization]"]').selectOption(mode);
  await form.locator("button[type=submit]").click();
  await expect(page.locator(`code:text-is("${name}")`)).toBeVisible();
}

/** @param {import("@playwright/test").Page} page @param {string} name */
function fieldInput(page, name) {
  return page.locator(`input[name$="[custom_fields][${name}]"]`);
}

// Press the editor's publish button and wait for its flash: "Publish now" on
// a draft, "Publish changes" on a live page with a pending draft.
const PUBLISH_NOW = { name: /^publish now$/i, flash: "Updated to Published." };
const PUBLISH_CHANGES = { name: /^publish changes$/i, flash: "Published your changes." };

/** @param {import("@playwright/test").Page} page @param {{name: RegExp, flash: string}} button */
async function publish(page, { name, flash: message }) {
  const flash = page.locator("#flash-info");
  if (await flash.isVisible()) {
    await flash.click();
    await expect(flash).toBeHidden();
  }
  await page.getByRole("button", { name }).click();
  await expect(flash).toContainText(message);
}

test.describe("field-level localization", () => {
  /** @type {string} */
  let stamp;
  /** @type {string} */
  let shared;
  /** @type {string} */
  let fallback;
  /** @type {string[]} */
  let ids;
  /** @type {string[] | undefined} */
  let locales;

  test.beforeEach(async ({ page }) => {
    stamp = String(Date.now());
    shared = `e2e_shared_${stamp}`;
    fallback = `e2e_fallback_${stamp}`;
    ids = [];
    locales = undefined;
    await signInAsAdmin(page);
    locales = await setLocales(page, ["en", "fr"]);
  });

  test.afterEach(async ({ page }) => {
    // Translation first: it is the newer row of the slug.
    for (const id of ids.reverse()) await deleteContentById(page, "page", id);

    // Page fields apply to every page in every later spec, so none may stay.
    await page.goto("/editor/fields");
    const fields = page
      .locator('li[id^="field-"]')
      .filter({ has: page.locator(`code:text-matches("^e2e_(shared|fallback)_${stamp}$")`) });
    for (let n = await fields.count(); n > 0; n--) {
      page.once("dialog", dialog => dialog.accept());
      await fields.first().getByRole("button", { name: "Delete field" }).click();
      await expect(fields).toHaveCount(n - 1);
    }

    if (locales) await setLocales(page, locales);
  });

  test("a shared field follows the source; an empty fallback field inherits it", async ({ page }) => {
    await createPageField(page, shared, "shared");
    await createPageField(page, fallback, "fallback");

    // The EN source, published with a value in each field.
    const slug = `floc-${stamp}`;
    const enId = await newDraftPage(page);
    ids.push(enId);
    await fieldInput(page, shared).fill("Ten euros");
    await fieldInput(page, fallback).fill("Inherited caption");
    await saveDraft(page, { title: `Localized ${stamp}`, slug });
    // No translation yet: the source says so instead of a count of one.
    await expect(page.locator("[data-localization=shared]")).toContainText("Shared with 0 other locales");
    await publish(page, PUBLISH_NOW);

    // Create translation → FR, from the History tab's Translations list.
    await page.click('button[role="tab"][phx-value-tab="history"]');
    await page.locator('button[phx-click="create_translation"][phx-value-locale="fr"]').click();
    await page.waitForURL(url => /\/editor\/content\/page\/[0-9a-f-]{36}$/.test(url.pathname) && !url.pathname.endsWith(enId));
    const frUrl = page.url();
    const frId = new URL(frUrl).pathname.split("/").pop() || "";
    ids.push(frId);

    // The shared field is read-only here and says where it is edited.
    const frShared = fieldInput(page, shared);
    await expect(frShared).toHaveValue("Ten euros");
    await expect(page.locator(`fieldset[disabled] input[name$="[custom_fields][${shared}]"]`)).toBeAttached();
    await expect(frShared).toBeDisabled();
    await expect(page.locator("[data-localization=shared]")).toContainText("Shared: edited in the EN version.");
    await expect(page.locator("[data-localization=shared]").getByRole("link", { name: "Open" })).toHaveAttribute(
      "href",
      `/editor/content/page/${enId}`,
    );

    // A translation starts as a copy of every field, so the fallback field
    // holds the EN value; emptied, it shows what readers get instead.
    const frFallback = fieldInput(page, fallback);
    await expect(frFallback).toHaveValue("Inherited caption");
    await frFallback.fill("");
    await save(page);
    await page.reload();
    await expect(frFallback).toHaveValue("");
    await expect(frFallback).toHaveAttribute("placeholder", "Inherited caption");
    await expect(page.locator("[data-localization=fallback]")).toContainText("readers get the EN value");

    // Change the EN value and publish: SharedFieldsWorker copies it into the
    // FR draft. It runs on Oban, after the publish returns, so reload until
    // the value shows.
    await page.goto(`/editor/content/page/${enId}`);
    await fieldInput(page, shared).fill("Twelve euros");
    await save(page);
    await publish(page, PUBLISH_CHANGES);

    await page.goto(frUrl);
    await expect(async () => {
      await page.reload();
      await expect(fieldInput(page, shared)).toHaveValue("Twelve euros", { timeout: 1_000 });
    }).toPass({ timeout: 20_000 });

    // Publish FR with the fallback still empty: the public FR document carries
    // the inherited value, and says where it came from. Custom fields reach
    // readers through the delivery API (the built-in HTML page renders none),
    // and the artifact is fired by a job, so poll.
    await publish(page, PUBLISH_NOW);
    await expect(async () => {
      const res = await page.request.get(`/api/content/page/${slug}?locale=fr`);
      expect(res.status()).toBe(200);
      const body = await res.json();
      expect(body.locale).toBe("fr");
      expect(body.custom_fields).toMatchObject({ [shared]: "Twelve euros", [fallback]: "Inherited caption" });
      expect(body.inherited_fields).toEqual({ custom_fields: { [fallback]: "en" } });
    }).toPass({ timeout: 20_000 });
  });
});
