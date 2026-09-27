// @ts-check
//
// The passkey button on /sign-in (#331, #1681). It is server-rendered hidden by
// `KilnCMSWeb.SignInLive`, and the `PasskeySignIn` hook reveals it only where
// WebAuthn exists. Two claims a LiveViewTest cannot check, because they are
// about what the browser does with that markup:
//
//   * a browser with `PublicKeyCredential` shows the button, and revealing it
//     trips no CSP rule (the hook is bundled JS, no inline script);
//   * one without it never does — no button that cannot work.
const { test, expect, waitForLiveConnected } = require("./fixtures");

const passkeyButton = (page) => page.getByRole("button", { name: "Use a passkey" });

test.describe("passkey sign-in button (#1681)", () => {
  test("is revealed where WebAuthn exists, with no CSP violation", async ({ page }) => {
    const cspViolations = [];
    await page.addInitScript(() => {
      document.addEventListener("securitypolicyviolation", (e) =>
        // @ts-ignore
        (window.__csp = (window.__csp || []).concat(e.effectiveDirective)),
      );
    });
    page.on("console", (msg) => {
      if (/Content Security Policy/i.test(msg.text())) cspViolations.push(msg.text());
    });

    await page.goto("/sign-in");
    await waitForLiveConnected(page);

    const hasWebAuthn = await page.evaluate(() => typeof window.PublicKeyCredential !== "undefined");
    test.skip(!hasWebAuthn, "this engine exposes no PublicKeyCredential");

    await expect(passkeyButton(page)).toBeVisible();

    // @ts-ignore
    expect(await page.evaluate(() => window.__csp || [])).toEqual([]);
    expect(cspViolations).toEqual([]);
  });

  test("stays hidden in a browser without WebAuthn", async ({ page }) => {
    await page.addInitScript(() => {
      // @ts-ignore
      delete window.PublicKeyCredential;
    });

    await page.goto("/sign-in");
    await waitForLiveConnected(page);

    await expect(page.locator("#passkey-sign-in [data-role=passkey-sign-in]")).toHaveCount(1);
    await expect(passkeyButton(page)).toBeHidden();
  });
});
