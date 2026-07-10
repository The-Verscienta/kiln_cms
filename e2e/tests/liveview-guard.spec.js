// @ts-check
// Regression guard for the LiveView navigation fixture (see fixtures.js).
//
// Once app.js loads, LiveView binds phx-click / phx-submit controls and
// suppresses their native fallback, so a click issued between "JS bound" and
// "channel joined" is swallowed. That window is invisible locally but wide
// enough on a cold CI runner to hang sign-in on /sign-in (the flake this
// fixture was written for).
//
// Here we widen the window deliberately — the LiveView socket is held back for
// well over a second — and then drive the sign-in form the naive way: navigate,
// fill, click, with no explicit wait. It passes only because `page.goto` waits
// for the socket. Drop the fixture and this test hangs on /sign-in again.
const { test, expect } = require("./fixtures");

const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

test("a phx-submit issued right after page load survives a slow LiveView socket", async ({
  page,
}) => {
  await page.routeWebSocket(/\/live/, async ws => {
    await new Promise(resolve => setTimeout(resolve, 1600));
    ws.connectToServer();
  });

  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();

  await expect(page).toHaveURL("/editor/overview");
});
