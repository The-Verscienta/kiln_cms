// @ts-check
// The two reconnect toasts — "We can't find the internet" (#client-error) and
// "Something went wrong!" (#server-error) — must come down once the page is
// connected again, and only the one for the view's current trouble may stand
// (#1784).
//
// LiveView raises them with a one-shot `phx-disconnected` command and lowers
// them with a one-shot `phx-connected` one (`Layouts.flash_group/1`). A view
// can leave an error state without the second ever arriving: a rejoin that
// fails swaps `phx-client-error` for `phx-server-error`, and before the fix
// "We can't find the internet" stayed up beside "Something went wrong!" — the
// pair a tester found on every console page. app.css now ties each toast to
// the container's class.
//
// The line is cut from the test side with `page.routeWebSocket`, which also
// holds the reconnect back long enough for the toast's half-second grace to
// pass, so each case really shows a toast before asking it to go.
const { test, expect, signInAsAdmin, waitForLiveConnected, holdsAcross } = require("./fixtures");

// Both read `null` while the page is between documents (LiveView reloads it
// after a refused join), so a poll keeps polling instead of throwing.
const toasts = page =>
  page
    .evaluate(() => {
      const shown = id => {
        const el = document.getElementById(id);
        return !!el && el.checkVisibility();
      };
      return { client: shown("client-error"), server: shown("server-error") };
    })
    .catch(() => null);

const mainClass = page =>
  page
    .evaluate(() => document.querySelector("[data-phx-main]")?.className || "")
    .catch(() => "");

test.describe("reconnect toasts", () => {
  /** @type {import("@playwright/test").WebSocketRoute | null} */
  let line = null;
  // How long the next connection is held before it reaches the server.
  let holdMs = 0;
  // Answer the next connection's first LiveView join with an error.
  let refuseNextJoin = false;

  test.beforeEach(async ({ page }) => {
    holdMs = 0;
    refuseNextJoin = false;

    await page.routeWebSocket(/\/live\/websocket/, async ws => {
      if (holdMs) await new Promise(resolve => setTimeout(resolve, holdMs));
      line = ws;

      if (!refuseNextJoin) {
        ws.connectToServer();
        return;
      }

      refuseNextJoin = false;
      const server = ws.connectToServer();
      let refused = false;
      ws.onMessage(message => server.send(message));
      server.onMessage(message => {
        // [join_ref, ref, topic, event, payload] — a join's reply carries its
        // own ref as the join ref.
        const frame = JSON.parse(String(message));
        const joinReply =
          frame[3] === "phx_reply" && String(frame[2]).startsWith("lv:") && frame[0] === frame[1];

        if (joinReply && !refused) {
          refused = true;
          frame[4] = { status: "error", response: { reason: "e2e refused join" } };
          ws.send(JSON.stringify(frame));
        } else {
          ws.send(message);
        }
      });
    });

    await signInAsAdmin(page);
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: false });
  });

  test("a line that drops and comes back takes its toast down", async ({ page }) => {
    holdMs = 1500;
    await line?.close({ code: 4000, reason: "e2e drop" });

    await expect.poll(() => toasts(page)).toEqual({ client: true, server: false });

    await waitForLiveConnected(page);
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: false });
    // And it stays down: nothing late puts it back.
    await holdsAcross(page, () => toasts(page), { client: false, server: false });
  });

  test("a rejoin that fails leaves only the toast for the error the page is in", async ({
    page,
  }) => {
    holdMs = 1500;
    refuseNextJoin = true;
    await line?.close({ code: 4000, reason: "e2e drop" });

    await expect.poll(() => toasts(page)).toEqual({ client: true, server: false });

    // The line is back but the view is not: LiveView calls that a server error.
    await expect.poll(() => mainClass(page)).toContain("phx-server-error");
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: true });

    // LiveView answers a refused join by reloading the page; the reloaded page
    // joins, and neither toast survives it.
    await expect.poll(() => mainClass(page), { timeout: 20_000 }).toContain("phx-connected");
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: false });
  });

  test("the liveness watchdog's rebuild of a quiet line leaves no toast behind", async ({
    page,
  }) => {
    // Starve the watchdog (assets/js/liveness.js): its pings go unanswered, the
    // line goes quiet, and it takes the socket down and builds it again.
    await page.evaluate(() => {
      const socket = /** @type {any} */ (window).liveSocket.socket;
      socket.ping = () => false;
    });

    await expect
      .poll(() => page.evaluate(() => document.documentElement.classList.contains("phx-late")), {
        timeout: 20_000,
      })
      .toBe(true);

    await waitForLiveConnected(page);
    await expect
      .poll(() => page.evaluate(() => document.documentElement.classList.contains("phx-late")), {
        timeout: 20_000,
      })
      .toBe(false);
    await holdsAcross(page, () => toasts(page), { client: false, server: false });
  });
});
