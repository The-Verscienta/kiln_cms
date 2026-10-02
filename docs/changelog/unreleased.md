# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="on-fly-io-railway-and-digitalocean-rate-limits-can-be-per-visitor"></a>

- **On Fly.io, Railway and DigitalOcean, rate limits can be per visitor:
  `CLIENT_IP_HEADER` reads the platform proxy's own client-address header.**
  Per-IP rate limits, including the brute-force protection on `/sign-in` and
  `/api/auth/sign_in`, need the client's address. Behind a proxy Kiln takes it
  from `X-Forwarded-For`, but only once `TRUSTED_PROXIES` names the proxy, and
  none of the one-click platforms publishes its proxy's address range. On
  DigitalOcean, `X-Forwarded-For` holds the ingress address anyway. So those
  deployments had one shared bucket for every visitor.

  Each of three platforms writes the client address into a header of its own:
  `Fly-Client-IP`, Railway's `X-Real-IP`, and DigitalOcean's
  `do-connecting-ip`. Set `CLIENT_IP_HEADER` to one of them and Kiln uses it,
  ahead of `TRUSTED_PROXIES`. A header is trusted with no peer check, which is
  only safe where every request comes through the platform's proxy, so Kiln
  also requires that platform's own variables (`FLY_APP_NAME` and
  `FLY_MACHINE_ID`; `RAILWAY_SERVICE_ID` and `RAILWAY_ENVIRONMENT_ID`; `APP_ID`
  bound to `${APP_ID}` on App Platform). Without them, or with any other header
  name, the setting is ignored and one error is logged, so a copy on a server
  the internet reaches directly can't let clients choose their own bucket.

  `fly.toml` and `.do/app.yaml` now set it, and the Railway recipe lists it.
  Render documents no such header and is unchanged. One gap is left: sockets
  only receive `x-` headers, so on Fly and DigitalOcean the `/sign-in` form,
  which submits over the live connection, still shares a bucket per
  deployment. A new test also parses `render.yaml`, `fly.toml` and
  `.do/app.yaml` and checks the pinned tag, secrets, database, health check
  and header wiring (#1529).
  ([#1548](https://github.com/The-Verscienta/kiln_cms/issues/1548))

## Fixed

<a id="ci-no-longer-fails-at-random-with-type-oban-job-state-can-not-be"></a>

- **CI no longer fails at random with "type `_oban_job_state` can not be
  handled": the suite loads every database type before its first test.**
  Postgrex keeps one cache of database types per database, shared by the
  whole pool, and loads a type it hasn't seen the first time a query uses
  it. It adds a batch of new types in two steps: first the rows, then how to
  decode each. A query on another connection that lands between the two
  steps fails with "can not be handled", and a moment later the same query
  works. A script that aims at that window reproduces it: 376 failures
  across 6,000 freshly created types with 30 concurrent connections.

  In CI every shard starts from an empty database, and `mix test` runs
  `ash.setup` in the same VM, so the cache is filled before the migrations
  create anything. The types they add were then first loaded by the test
  suite, with eight async tests starting at once. Before 2026-10-01 that
  included Oban's job-state enum, which a publish's unique job insert uses.
  Today it is `citext`, `vector`, `halfvec` and `sparsevec`. Locally the test
  database is usually migrated already, which is why it only failed in CI.

  `test_helper.exs` now loads every such type in one query before ExUnit
  starts, and a new test fails if any is missing from the cache when tests
  run. It failed on all 27 completed fresh-database runs without the
  warm-up and passed on all 30 with it. `KilnCMS.PostgrexTypes` also
  registers pgvector's `halfvec` and `sparsevec` codecs, so every type the
  extension installs can be loaded. Production is unaffected: its migrations
  run in a separate VM before the server starts, so the server's cache is
  filled after them.
  ([#1796](https://github.com/The-Verscienta/kiln_cms/issues/1796))

<a id="concluding-an-experiment-now-refuses-a-winner-that-is-not-one-of-its-own"></a>

- **Concluding an experiment now refuses a winner that is not one of its own
  variants.**
  `:conclude` took `winner_variant_id` as a `:uuid` argument and wrote it
  straight to the attribute, so the type was the only gate: a non-uuid was
  refused and any well-formed uuid was accepted and stored — one belonging to no
  variant at all, or to a variant of a different experiment on the same site.

  Nothing mis-read it. `Promotion` looks the winner up among *this* experiment's
  arms and answers `:winner_missing`, so no wrong copy was ever written into a
  document. The cost was the row, and the row could not be corrected:
  `winner_variant_id` is `writable? false`, the state machine has no
  `concluded → concluded` transition, and `:update` refuses anything but a
  draft — so all three remedies were shut and nothing short of SQL took the bad
  id back out.

  What it left behind contradicted itself. The Promote button renders on
  `state == :concluded and winner_variant_id`, so it was offered and could never
  succeed, while `winner?/2` matched no row so no `winner` badge showed. The
  page said both "there is a winner to promote" and "no arm won", and the only
  way out was to archive the experiment. The dangling id also shipped in the
  `experiment.concluded` payload, to webhook endpoints, automation rules and
  federation, where nothing could tell it from a real one.

  Ordinary use never produced one. `mix kiln.experiment conclude --winner NAME`
  resolves the name among the experiment's variants and raises on one that is
  not there, and the editor's `<select>` is built from `@experiment.variants` —
  whose options cannot even go stale, because `RefuseWhenRunning` freezes the
  arms for as long as the conclude form is on screen. The action was the only
  layer without the check, which is the layer a crafted LiveView event and any
  other caller of the `conclude_experiment/3` code interface reach.

  `Validations.WinnerIsAVariant` now refuses it, on `field: :winner_variant_id`.
  Concluding with no winner is unchanged — it is a real choice, and the common
  outcome for a test that found no difference. The check reads the arms as the
  system actor with `authorize_with: :error` so it fails closed: a refused read
  answers `[]` under a filter policy, which would otherwise read as "not an arm"
  and refuse a perfectly good winner.
  ([#1851](https://github.com/The-Verscienta/kiln_cms/pull/1851))

