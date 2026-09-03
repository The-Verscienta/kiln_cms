# Browser E2E suite (Playwright)

Real-browser journeys against a real Phoenix server (`MIX_ENV=e2e`), built
assets, and a persistent database — no SQL sandbox. See
`playwright.config.js` for the authoritative wiring; this file covers the
knobs and the traps.

## Running it

```sh
cd e2e
npm ci
npx playwright install chromium webkit
npx playwright test                 # boots the server itself (mix e2e.setup + phx.server)
npx playwright test tests/editor.spec.js --project=chromium   # one spec
```

The config starts the server for you and **reuses one already listening on
the port** (locally; never in CI). Before any spec runs, a per-worker check
asks the server which checkout it is (`GET /dev/e2e-identity`, an
e2e/dev-only route) and refuses a mismatch — the alternative was every spec
failing at sign-in because an orphaned server from a *sibling worktree* was
still holding the port (#1353). If it refuses, stop the foreign server
(`lsof -i :4002`) or run on a free port.

## Knobs

| Env | Default | Meaning |
|---|---|---|
| `PORT` | `4002` | Server port; also drives `baseURL`. |
| `POSTGRES_DB` | `kiln_cms_e2e_<checkout dirname>` | The suite's database. Partitioned per checkout by default (#1353) so two worktrees never pollute each other's persistent data. |
| `E2E_BASE_URL` | `http://localhost:$PORT` | Point the specs at a server you started yourself. |
| `E2E_NO_WEBSERVER` | unset | Set to skip starting a server (CI starts its own). |

## The database is persistent — and that is load-bearing

Specs run serially against data that survives between specs and between
runs. Two consequences:

- **Fixtures must be self-scoped**: unique slugs/titles per run, tag groups
  scoped to their content types, cleanup in `finally`. An unscoped leftover
  can make another spec's empty-state unreachable forever (it has happened —
  see the comments in `editor.spec.js`'s tag-picker journey).
- **When the data is beyond saving**: `MIX_ENV=e2e mix e2e.reset` drops and
  rebuilds the (per-checkout) database with demo seeds.

## Waiting discipline

No `page.waitForTimeout` (#1352). Wait on a condition the patch itself
renders — the preview pane for pushed content, server-rendered counts, the
tab title after an autosave — or, for "a patch must NOT change X" claims,
`holdsAcross` from `fixtures.js`, which samples the claim across the
debounce window instead of sleeping past it. `tag_picker_midsession.spec.js`
documents why an auto-retrying `expect` is sometimes exactly wrong.

## Retries are counted, not free

CI runs with `retries: 1` so a single flake doesn't fail the job — but every
test that passed only on retry is surfaced by name in the job summary and in
the uploaded `playwright-report` artifact (#1353). A spec showing up there
repeatedly is a flake to fix, not noise to ignore.
