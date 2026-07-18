# Deploying the P2 features

Deploy checklist for the 2026-07 P2 feature set: signed provenance (#340),
static/edge export (#353), DB-outage-resilient delivery (#341), editorial
automation (#342), and multiplayer live preview (#343). Plus the
runtime/marketplace extensibility scoping (#333) — a **no-op deploy**, see the
table row and §6.

Production is a **manual Coolify _Redeploy_** on the VPS. A Redeploy rebuilds the
image (running `mix assets.deploy` at build time) and runs pending migrations at
container start (`bin/migrate` → `KilnCMS.Release.migrate`, per the container
`CMD`). So the mechanical steps are automatic — **verify, don't hand-run.**

## What changed (deploy-relevant)

| Feature | Schema | Assets | New env/config | New Oban queue |
| --- | --- | --- | --- | --- |
| #340 provenance | none (stateless) | none | **only if enabling** (off by default) | none |
| #353 static export | none | none | optional (`output_dir`) | none (`:default`) |
| #341 DB-outage delivery | none | none | none | none |
| #342 automation | **1 migration** (`automation_rules`) | none | none (rules are UI-created) | none (`:default`) |
| #343 multiplayer preview | none | **JS hook** (`PreviewCursors`) | none | none |
| #333 extensibility scoping | none | none | none | none |

Key points:

- **One migration** total — `…_add_automation_rules.exs` (creates `automation_rules`).
  It runs automatically at boot; it's additive and unused by other features.
- **Assets rebuild** is required for #343's cursor hook, handled automatically by
  `mix assets.deploy` in the image build. Deploying a *prebuilt* image without a
  rebuild would omit the hook (presence still works; cursors wouldn't broadcast).
- **No new *required* env vars.** Everything new is off-by-default or UI-driven.
- **POOL_SIZE: no change.** No Oban queue was added — `RuleWorker` (#342) and
  `StaticExportWorker` (#353) run on the existing `:default` queue, so total
  worker concurrency (~37) is unchanged. (See `docs/performance.md` for the
  POOL_SIZE ↔ queue-concurrency relationship.)

## 1. Pre-deploy

- [ ] Deploy `main` at/after the commit that merged all five (the `#342`/`#343`
      squash merges).
- [ ] Decide whether to enable the two config-gated features now or later (§4).
      No decision is needed to deploy — they stay off.
- [ ] Back up Postgres before the migration, per your normal routine.

## 2. Deploy

- [ ] In Coolify, **Redeploy** the app (full image rebuild).
- [ ] Watch the **build** logs for `mix assets.deploy` and `mix release`
      succeeding (the build also asserts the API routers ship).

## 3. Post-deploy verification

- [ ] **Migration ran** — startup logs show `bin/migrate` applying
      `add_automation_rules` (or "Already up"), and the app booted (not
      crash-looping on migrate).
- [ ] **App healthy** — `GET /up` returns `200`.
- [ ] **#342 automation** — as an **admin**, `/editor/automation` loads and you
      can add a rule (non-admin/anonymous should be bounced). Optionally add a
      `broadcast`/`invalidate_cache` rule and publish an item to see it fire.
- [ ] **#343 preview** — open a content item's **Preview** pop-out in two
      browsers/users on the same item: each shows the other in the presence bar
      ("2 viewing") and a moving cursor. This exercises the LiveView
      **WebSocket + Presence** path (already required by the editor — just
      confirm WS still passes through the proxy).
- [ ] **#341 resilience** — nothing to configure; it relies on `KilnCMS.Cache`
      being enabled (the default). Do **not** set
      `config :kiln_cms, KilnCMS.Cache, enabled: false`.

## 4. Optional — enable the config-gated features

### #340 provenance (off by default)

In `runtime.exs` / Coolify env:

```elixir
config :kiln_cms, KilnCMS.Provenance,
  enabled: true,
  signer: "Verscienta Editorial",
  origin: "https://your-domain",
  # Reuse the DKIM mail key, or point at a dedicated content-signing key:
  signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}   # or  :dkim
```

- [ ] Provide a **PKCS#1 RSA PEM** in `KILN_PROVENANCE_PRIVATE_KEY` (same format
      as DKIM), or set `signing_key: :dkim` to reuse the mail key.
- [ ] Verify — `GET /api/provenance/public-key` returns the key, and a published
      item's `GET /api/provenance/:type/:slug/verify` returns `"verified": true`.
- [ ] Note: rotating the key changes `key_id`; manifests verify against the
      *current* key. Plan rotation deliberately. See `docs/provenance.md`.

### #353 static export (optional)

Only needed for CDN / edge / air-gapped snapshots:

```elixir
config :kiln_cms, KilnCMS.Firing.StaticExport, output_dir: "/data/edge"
```

- [ ] Ensure `output_dir` is a **writable, persisted** path (a Coolify volume) —
      not ephemeral container storage.
- [ ] Run once to confirm:
      `bin/kiln_cms eval 'KilnCMS.Firing.StaticExport.export("/data/edge")'`
      (or enqueue `KilnCMS.Firing.StaticExportWorker`), then check `index.json`
      and the `content/…` tree. See `docs/static-export.md`.
- [ ] For periodic export, wire an Oban cron entry for `StaticExportWorker` (not
      added by default).

## 5. Rollback

- [ ] Redeploy the previous image tag. The `automation_rules` table is additive
      and unused elsewhere, so it can stay; nothing else changed schema. There is
      no data migration to reverse.

## 6. #333 extensibility scoping — nothing to deploy

#333 (PR #380) is **docs + a decision + an inert lightweight registry** — it
changes no runtime behavior on a stock install:

- **No migration, no assets, no env/config, no new Oban queue.** It ships on the
  same plain Redeploy as everything above with zero extra steps.
- **The decision it records:** Kiln does **not** hot-load arbitrary plugin code
  at runtime (the BEAM has no in-process sandbox). Nothing to configure — this
  ratifies the existing compile-time plugin model (D18/D4). See
  `docs/plugin-extensibility.md`.
- **The registry additions are inert by default:** the new optional
  `version/0`/`summary/0`/`homepage/0` plugin metadata and
  `Kiln.Plugins.manifests/0` only surface data for plugins that are *already
  installed* (i.e. compiled into the image and listed in
  `config :kiln_cms, :plugins`). Production ships with that list empty, so there
  is no new surface to verify.
- **New ops tool (optional, discovery only):** `mix kiln.plugins.list` prints
  installed plugins with their catalog metadata and contribution surface. Mix
  tasks aren't packaged in a release, so this is a **build/dev-shell** aid, never
  run in production or automatically. From a release, the equivalent is
  `bin/kiln_cms eval 'Kiln.Plugins.manifests()'`.

There is no post-deploy check specific to #333 — a successful boot is the whole
story. Rollback is likewise a no-op (docs + code, no schema).

---

**Bottom line:** a plain Redeploy of `main` ships #341, #343, and #342 (incl. the
automation table and the preview cursor hook) with no manual steps beyond
verifying boot. #340 and #353 do nothing until you opt in via §4. #333 is docs +
an inert registry — nothing to deploy or verify (§6). No POOL_SIZE change, no new
required secrets.
