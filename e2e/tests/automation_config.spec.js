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
    await page.locator("#rule_action").selectOption("send_email");
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
    await page.locator("#rule_action").selectOption("suggest_metadata");
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
});
