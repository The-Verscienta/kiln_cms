// @ts-check
// The automation rule form's generated settings (KilnCMSWeb.AutomationLive.
// ConfigFields). automation_live_test.exs covers which inputs render and what
// they save; what it cannot see is the browser half: the placeholder chips
// are a client hook that edits the field at the caret, and only a real
// `input` event proves phx-change picks the edit up.
const { test, expect, signInAsAdmin } = require("./fixtures");

const form = page => page.locator("#new-rule-form");

test.describe("automation rule settings", () => {
  test.beforeEach(async ({ page }) => {
    await signInAsAdmin(page);
    await page.goto("/editor/automation");
  });

  test("a placeholder chip inserts at the caret, and the save keeps it", async ({ page }) => {
    const name = `Chip rule ${Date.now()}`;
    await page.locator("#rule_name").fill(name);
    await form(page).getByText("Send an email", { exact: true }).click();
    await page.locator("#rule_config_to").fill("team@example.com");

    const subject = page.locator("#rule_config_subject");
    await subject.fill("Live: ");
    await subject.press("End");
    await form(page)
      .locator("#rule_config_subject-wrap")
      .getByRole("button", { name: "Insert the Title placeholder" })
      .click();

    await expect(subject).toHaveValue("Live: {{title}}");
    await expect(subject).toBeFocused();

    await form(page).getByRole("button", { name: "Add rule" }).click();
    await expect(page.getByText("Rule added.")).toBeVisible();
    const row = page.locator("li", { hasText: name });
    await expect(row).toBeVisible();

    // Removed again: an enabled "email on every publish" rule left in the
    // shared e2e database would fire under every later spec that publishes.
    page.once("dialog", dialog => dialog.accept());
    await row.getByRole("button", { name: "Delete rule" }).click();
    await expect(row).toHaveCount(0);
  });

  test("the deliver-as cards swap the fields they need", async ({ page }, testInfo) => {
    await form(page).getByText("Draft SEO metadata", { exact: true }).click();
    await expect(page.locator("#rule_config_to")).toBeVisible();
    await expect(page.locator("#rule_config_assignee")).toHaveCount(0);

    await form(page).getByText("Assign follow-up to a person").click();

    await expect(page.locator("#rule_config_assignee")).toBeVisible();
    await expect(page.locator("#rule_config_due_in_days")).toBeVisible();
    await expect(page.locator("#rule_config_to")).toHaveCount(0);

    await form(page).screenshot({
      path: testInfo.outputPath("automation-settings-task.png"),
      animations: "disabled",
    });
  });

  test("the builder reads back the rule as one sentence", async ({ page }, testInfo) => {
    await form(page).getByText("Send the newsletter", { exact: true }).click();
    await expect(page.locator("#rule_config_segment_id")).toBeVisible();
    await expect(page.locator("#rule_summary")).toContainText(
      "When any content is published, send the newsletter to all subscribers."
    );

    // The chosen card is the checked radio, reachable from the keyboard.
    await expect(page.locator("#rule_action_newsletter")).toBeChecked();

    await form(page).screenshot({
      path: testInfo.outputPath("automation-builder.png"),
      animations: "disabled",
    });
  });

  test("a recipe fills the builder, and the gallery keeps the admin's fold", async ({ page }, testInfo) => {
    const gallery = page.locator("details#recipes");
    const isOpen = () => gallery.evaluate(el => el.open);

    // The server renders the gallery open only while the site has no rules,
    // and the shared e2e database may or may not have some. Either way, the
    // admin's own open/fold must survive a re-render that doesn't change the
    // server's default. Opening it and then picking a recipe covers "server
    // says folded"; folding it and then changing the form covers "server
    // says open".
    if (!(await isOpen())) await gallery.locator("summary").click();

    await page.locator("#recipe-task-when-stale").click();
    await expect(page.locator("#recipe-banner")).toContainText("Create a task when content goes stale");
    await expect(page.locator("#rule_action_create_task")).toBeChecked();
    await expect(page.locator("#rule_summary")).toContainText(
      "When any content is past its review date, create a task for the author."
    );
    expect(await isOpen()).toBe(true);

    await page.locator("details#recipes").screenshot({
      path: testInfo.outputPath("automation-recipes.png"),
      animations: "disabled",
    });

    await gallery.locator("summary").click();
    expect(await isOpen()).toBe(false);
    await page.locator("#rule_content_type").selectOption({ index: 1 });
    await expect(page.locator("#rule_summary")).not.toContainText("any content");
    expect(await isOpen()).toBe(false);
  });

  test("try it renders the email the rule would send, in a sandboxed frame", async ({ page }, testInfo) => {
    const cspViolations = [];
    page.on("console", msg => {
      if (/Content Security Policy/i.test(msg.text())) cspViolations.push(msg.text());
    });

    await form(page).getByText("Send an email", { exact: true }).click();
    await page.locator("#rule_config_to").fill("team@example.com");
    await page.getByRole("button", { name: "Try it on real content" }).click();

    const picker = page.locator("#preview_record");
    await expect(picker).toBeVisible();
    await picker.selectOption({ index: 1 });

    const effects = page.locator("#preview-effects");
    await expect(effects).toContainText("Email to team@example.com");
    await expect(effects).toContainText("Subject: Kiln automation:");

    // The default body names the event; the frame must actually render it.
    const frame = effects.locator("iframe");
    await expect(frame).toHaveAttribute("sandbox", "");
    await expect(page.frameLocator("#preview-effects iframe").locator("body")).toContainText("emitted");
    expect(cspViolations).toEqual([]);

    await page.locator("#try-it").screenshot({
      path: testInfo.outputPath("automation-try-it.png"),
      animations: "disabled",
    });
  });
});
