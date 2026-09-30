// @ts-check
//
// The eye button beside the password boxes on /sign-in and /register (#1806).
// LiveViewTest checks the button is rendered with the right aria; these are the
// claims only a browser can check, because they are about what the JS command
// on the button does:
//
//   * a click flips the box between dots and plain text, and the button's
//     aria-pressed / aria-label with it — without submitting the form;
//   * the flip survives a LiveView patch. Typing pushes a validation round trip,
//     and a patch re-renders the box with `type="password"`; the JS command's
//     attributes are sticky, so LiveView puts them back. Without that, the box
//     would snap back to dots mid-word.
const { test, expect, waitForLiveConnected, holdsAcross } = require("./fixtures");

const signInForm = (page) => page.locator("form[action='/auth/user/password/sign_in']");

test.describe("password reveal toggle (#1806)", () => {
  test("shows and hides the sign-in password without submitting", async ({ page }) => {
    await page.goto("/sign-in");
    await waitForLiveConnected(page);

    const form = signInForm(page);
    const box = form.locator("input[name='user[password]']");
    const eye = form.getByRole("button", { name: "Show password" });

    await box.fill("hunter2-secret");
    await expect(box).toHaveAttribute("type", "password");
    await expect(eye).toHaveAttribute("aria-pressed", "false");

    await eye.click();
    await expect(box).toHaveAttribute("type", "text");
    const hide = form.getByRole("button", { name: "Hide password" });
    await expect(hide).toHaveAttribute("aria-pressed", "true");
    await expect(box).toHaveValue("hunter2-secret");
    await expect(page).toHaveURL(/\/sign-in$/);

    await hide.click();
    await expect(box).toHaveAttribute("type", "password");
    await expect(eye).toHaveAttribute("aria-pressed", "false");
  });

  test("stays shown across the validation round trip typing triggers", async ({ page }) => {
    await page.goto("/register");
    await waitForLiveConnected(page);

    const box = page.locator("input[name='user[password]']");
    const eye = page.locator(`#${await box.getAttribute("id")}-reveal`);

    await eye.click();
    await expect(box).toHaveAttribute("type", "text");

    // Type into the other boxes too, so the phx-change debounce fires and a
    // patch lands (the confirmation box's "does not match" is that patch).
    await box.pressSequentially("abc-typed");
    await page.locator("input[name='user[password_confirmation]']").pressSequentially("xyz");
    await expect(page.getByText("does not match")).toBeVisible();

    await holdsAcross(
      page,
      async () => ({
        type: await box.getAttribute("type"),
        pressed: await eye.getAttribute("aria-pressed"),
        label: await eye.getAttribute("aria-label"),
      }),
      { type: "text", pressed: "true", label: "Hide password" },
    );

    // The confirmation box has its own toggle and was never pressed.
    await expect(page.locator("input[name='user[password_confirmation]']")).toHaveAttribute(
      "type",
      "password",
    );
  });
});
