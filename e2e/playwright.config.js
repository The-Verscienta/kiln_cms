// @ts-check
const { defineConfig } = require("@playwright/test");

// The Phoenix endpoint reads its port from PORT (config/runtime.exs), so the
// server and the baseURL stay in sync via this one value. fixtures.js reads
// the resolved address back off this config, so its server-identity check
// (#1353) always interrogates the same server the specs hit.
const PORT = process.env.PORT || "4002";
const BASE_URL = process.env.E2E_BASE_URL || `http://localhost:${PORT}`;

// By default Playwright boots the Phoenix server itself (`mix e2e.server`,
// which builds assets, sets up the DB + demo seeds, then serves). In CI the
// server is started separately, so set E2E_NO_WEBSERVER=1 to skip that.
const webServer = process.env.E2E_NO_WEBSERVER
  ? undefined
  : {
      // Build assets + set up the DB/seeds, then serve in a fresh VM. Two steps
      // because `mix run seeds.exs` (inside e2e.setup) halts the VM, so the
      // server must be a separate invocation. PHX_SERVER=true turns serving on.
      command: `cd .. && MIX_ENV=e2e mix e2e.setup && MIX_ENV=e2e PHX_SERVER=true PORT=${PORT} mix phx.server`,
      url: BASE_URL,
      reuseExistingServer: !process.env.CI,
      // Generous: a cold run compiles the app in :e2e + downloads the
      // esbuild/tailwind binaries + builds assets before serving. CI now
      // pre-compiles :e2e in a separate step (see .github/workflows/ci.yml), so
      // this mainly covers cold *local* runs; kept high as defense-in-depth.
      timeout: 600_000,
      stdout: "pipe",
      stderr: "pipe",
    };

module.exports = defineConfig({
  testDir: "./tests",
  // The journeys touch persistent (non-sandboxed) data, so run serially.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  // CI adds the JSON report so retried-then-passed ("flaky") tests are
  // COUNTED, not silently absorbed by `retries: 1` (#1353): the workflow
  // reads it into the job summary and uploads it as an artifact on every
  // run, so flake frequency is measurable instead of invisible until a
  // spec fails twice in a row.
  reporter: process.env.CI
    ? [["github"], ["list"], ["json", { outputFile: "playwright-report/results.json" }]]
    : "list",
  use: {
    baseURL: BASE_URL,
    headless: true,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  // Use Playwright's bundled Chromium (no system Chrome required).
  //
  // WebKit runs one spec, not the suite: `focus_trap.spec.js` is about where
  // `document.activeElement` lands, and Safari not focusing a `<button>` on
  // click is the case that motivated #1046 — a Chromium-only run would leave
  // the reported symptom untested. The rest of the journeys are engine-agnostic
  // and doubling their runtime buys nothing.
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium", viewport: { width: 1280, height: 900 } },
    },
    {
      name: "webkit-focus",
      testMatch: /focus_trap\.spec\.js/,
      use: { browserName: "webkit", viewport: { width: 1280, height: 900 } },
    },
  ],
  webServer,
});
