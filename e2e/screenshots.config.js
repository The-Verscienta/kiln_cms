// @ts-check
// Captures the product screenshots shown on the signed-out home page
// (`page_html/home.html.heex`) into `priv/static/images/home/`. Not a test:
// it lives outside `./tests`, so neither `npx playwright test` nor CI picks it
// up. Re-run after a visible console change:
//
//     cd e2e && npx playwright test -c screenshots.config.js
//
// It reuses the journey config (same server, same seeds, same sign-in
// fixtures) and only swaps the test directory and the viewport.
const base = require("./playwright.config.js");

module.exports = {
  ...base,
  testDir: "./screenshots",
  timeout: 120_000,
  projects: [
    {
      name: "screenshots",
      use: {
        browserName: "chromium",
        viewport: { width: 1440, height: 900 },
        deviceScaleFactor: 2,
        colorScheme: "light",
        // The console formats times in the browser's zone; pin it so the
        // seeded 09:00 UTC schedules don't photograph as 4:00 AM.
        timezoneId: "UTC",
      },
    },
  ],
};
