// @ts-check
// Regression guard for the LiveView navigation fixture (see fixtures.js).
//
// Once app.js loads, LiveView binds phx-click / phx-submit controls and
// suppresses their native fallback, so a click issued between "JS bound" and
// "channel joined" is swallowed. That window is invisible locally but wide
// enough on a cold CI runner to hang sign-in on /sign-in (the flake this
// fixture was written for).
//
// Both tests widen that window deliberately and then drive the sign-in form
// the naive way: navigate, fill, click, with no explicit wait. They pass only
// because `page.goto` (via the fixture) waits for the view to be joined. Drop
// the fixture and they hang on /sign-in again.
const { test, expect } = require("./fixtures");

const ADMIN = { email: "admin@kiln.test", password: "kilnadmin123" };

// Slow *transport*: the WebSocket itself is held back for well over a second,
// so nothing LiveView is reachable until it opens.
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

// Slow *join*: the transport opens immediately (`liveSocket.isConnected()` is
// true) but every server→client frame — including the view's join ack — is
// delayed. Until that ack lands, `channel.canPush()` is false and LiveView
// rejects event pushes client-side, so a naive click is silently dropped.
// This is the exact shape of the CI cold-start flake: the server's first
// connected mount is slow, the suite's first sign-in click lands pre-join, and
// the page sits on /sign-in. The fixture must wait for the join (the
// `phx-connected` class), not just the socket.
test("a phx-submit issued right after page load survives a slow LiveView join", async ({
  page,
}) => {
  await page.routeWebSocket(/\/live/, ws => {
    const server = ws.connectToServer();
    ws.onMessage(message => server.send(message));
    // A fixed delay per frame preserves ordering (equal-delay timeouts fire
    // FIFO), so the join ack still arrives before any follow-up diffs.
    server.onMessage(message => {
      setTimeout(() => ws.send(message), 1600);
    });
  });

  await page.goto("/sign-in");
  await page.fill('input[name="user[email]"]', ADMIN.email);
  await page.fill('input[name="user[password]"]', ADMIN.password);
  await page.getByRole("button", { name: /sign in/i }).click();

  await expect(page).toHaveURL("/editor/overview");
});
