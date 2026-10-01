// @ts-check
// The two connection notices — "We can't find the internet" (#client-error)
// and "Something went wrong!" (#server-error), from `Layouts.flash_group/1`
// and assets/js/connection_notice.js.
//
// #1784: they must come down once the page is connected again, and only the
// one for the view's current trouble may stand. A rejoin that fails swaps
// `phx-client-error` for `phx-server-error`; before that fix "We can't find
// the internet" stayed up beside "Something went wrong!".
//
// #1821: neither may flash on a page that is fine. A notice now waits until
// the view has been in trouble for 2.5 s without a break, and carries a
// "Try again" button. The first load testers saw them on was Phoenix's
// WebSocket-to-longpoll fallback: a first connection slower than 2.5 s was
// swapped for longpoll, and the old socket's late close tore the new one down
// (fixed in phoenix 1.8.15), so the view sat in error until LiveView reloaded
// the page.
//
// The line is cut from the test side with `page.routeWebSocket`, which also
// holds the reconnect back for as long as a case needs.
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

// Every notice that has come up on this document, in order — a flash that
// came and went between two polls still lands here.
const seen = page => page.evaluate(() => /** @type {any} */ (window).__noticesSeen || []);

// Holds longer than Phoenix's 2.5 s fallback window would otherwise be cut
// short by a longpoll connection the route cannot see; these cases are about
// the WebSocket alone.
const noFallback = page =>
  page.evaluate(() => {
    /** @type {any} */ (window).liveSocket.socket.longPollFallbackMs = 0;
  });

test.describe("connection notices", () => {
  /** @type {import("@playwright/test").WebSocketRoute | null} */
  let line = null;
  // How long the next connection is held before it reaches the server.
  let holdMs = 0;
  // Answer the next connection's first LiveView join with an error.
  let refuseNextJoin = false;
  // Hold back every server frame on the next connection by this long: a
  // first connected mount (or a network) slower than the fallback window.
  let slowNextMs = 0;

  test.beforeEach(async ({ page }) => {
    holdMs = 0;
    refuseNextJoin = false;
    slowNextMs = 0;

    await page.addInitScript(() => {
      const w = /** @type {any} */ (window);
      w.__noticesSeen = [];
      // Documents loaded in this tab: a reload is the bug's tell.
      try {
        sessionStorage.setItem("e2e:loads", String(Number(sessionStorage.getItem("e2e:loads")) + 1));
      } catch (_) {
        // No storage on this document: the count is only read where it works.
      }
      new MutationObserver(records => {
        for (const { target } of records) {
          const el = /** @type {HTMLElement} */ (target);
          if ((el.id === "client-error" || el.id === "server-error") && !el.hidden) {
            w.__noticesSeen.push(el.id);
          }
        }
      }).observe(document, { subtree: true, attributes: true, attributeFilter: ["hidden"] });
    });

    await page.routeWebSocket(/\/live\/websocket/, async ws => {
      if (holdMs) await new Promise(resolve => setTimeout(resolve, holdMs));
      line = ws;

      if (slowNextMs) {
        const delay = slowNextMs;
        slowNextMs = 0;
        const server = ws.connectToServer();
        server.onMessage(message => setTimeout(() => ws.send(message), delay));
        return;
      }

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

  test("a first connection slow enough to fall back to longpoll shows nothing", async ({
    page,
  }) => {
    slowNextMs = 3000;
    await page.evaluate(() => sessionStorage.setItem("e2e:loads", "0"));
    await page.goto("/editor/overview");

    // Phoenix gives up on the slow WebSocket after 2.5 s and joins over
    // longpoll, on the document it loaded: no reload.
    await expect
      .poll(() => mainClass(page), { timeout: 15_000 })
      .toContain("phx-connected");
    expect(await page.evaluate(() => sessionStorage.getItem("e2e:loads"))).toBe("1");
    expect(
      await page.evaluate(() => /** @type {any} */ (window).liveSocket.socket.conn?.constructor.name),
    ).not.toBe("WebSocket");

    await holdsAcross(page, () => toasts(page), { client: false, server: false });
    expect(await seen(page)).toEqual([]);
  });

  test("a line that drops and comes straight back shows nothing", async ({ page }) => {
    holdMs = 1000;
    await line?.close({ code: 4000, reason: "e2e blip" });

    await expect.poll(() => mainClass(page)).toContain("phx-client-error");
    await expect.poll(() => mainClass(page)).toContain("phx-connected");
    await holdsAcross(page, () => toasts(page), { client: false, server: false });
    expect(await seen(page)).toEqual([]);
  });

  test("a line that stays down shows the notice, which goes when the line is back", async ({
    page,
  }) => {
    await noFallback(page);
    holdMs = 6000;
    await line?.close({ code: 4000, reason: "e2e drop" });

    // Not at once...
    await expect.poll(() => mainClass(page)).toContain("phx-client-error");
    await holdsAcross(page, () => toasts(page), { client: false, server: false }, { windowMs: 1500 });

    // ...but once the trouble has lasted.
    await expect.poll(() => toasts(page)).toEqual({ client: true, server: false });
    const notice = page.locator("#client-error");
    await expect(notice).toHaveAttribute("role", "alert");
    await expect(notice.getByRole("button", { name: "Try again" })).toBeVisible();

    await waitForLiveConnected(page);
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: false });
    // And it stays down: nothing late puts it back.
    await holdsAcross(page, () => toasts(page), { client: false, server: false });
  });

  test("Try again connects at once instead of waiting out the back-off", async ({ page }) => {
    // Phoenix's own next try is a minute away, so a connection inside the
    // test can only have come from the button.
    await page.evaluate(() => {
      const socket = /** @type {any} */ (window).liveSocket.socket;
      socket.longPollFallbackMs = 0;
      socket.reconnectTimer.timerCalc = () => 60_000;
    });
    await line?.close({ code: 4000, reason: "e2e drop" });

    await expect.poll(() => toasts(page)).toEqual({ client: true, server: false });
    await page.locator("#client-error").getByRole("button", { name: "Try again" }).click();

    await expect.poll(() => mainClass(page), { timeout: 5_000 }).toContain("phx-connected");
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: false });
  });

  test("a rejoin that fails leaves only the notice for the error the page is in", async ({
    page,
  }) => {
    await noFallback(page);
    holdMs = 4500;
    refuseNextJoin = true;
    await line?.close({ code: 4000, reason: "e2e drop" });

    await expect.poll(() => toasts(page)).toEqual({ client: true, server: false });

    // The line is back but the view is not: LiveView calls that a server
    // error. The outage goes on, so its notice follows at once, alone.
    await expect.poll(() => mainClass(page)).toContain("phx-server-error");
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: true });
    await expect(
      page.locator("#server-error").getByRole("button", { name: "Try again" }),
    ).toBeVisible();

    // LiveView answers a refused join by reloading the page; the reloaded page
    // joins, and neither notice survives it.
    await expect.poll(() => mainClass(page), { timeout: 20_000 }).toContain("phx-connected");
    await expect.poll(() => toasts(page)).toEqual({ client: false, server: false });
  });

  test("the liveness watchdog's rebuild of a quiet line leaves no notice behind", async ({
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
