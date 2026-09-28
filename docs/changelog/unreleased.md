# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

## Security

<a id="federation-runs-under-the-policies"></a>

- **Federation runs under the policies.** The inbox, the publish fan-out, the
  delivery worker, the replay-nonce store and its sweeper, and
  `mix kiln.federation` reached `Follower`, `Delivery`, `Block`,
  `SiteFederation` and `SeenSignature` through `authorize?: false`, which skips
  every policy on the resource. They now run as `KilnCMS.SystemActor`, and
  each resource admits it for exactly what it needs: the follower list in full,
  the delivery ledger's `create`/`settle` (not its prune), the block list's
  reads (not its writes), the site settings' read, delivery stamp and the
  operator's `enable`/`disable`/`rekey` (not the settings form), and the nonce
  store's `record`/`expired`/`destroy` (not a plain read). `KilnCMS.CMS.OrgSettings`
  gains a `system_actions:` option that narrows the grant inside the macro's
  policies. The `mix kiln.authz.check` backlog drops by 24 sites and five files.

  Two of those reads used to fail **open**, and now fail closed whatever the
  grants say. The replay-nonce write logged and accepted on the date window
  when the store refused or failed it; the inbox now answers such a delivery
  `503` with `Retry-After: 60`, so an honest sender retries it and a replay is
  never accepted unrecorded. And the inbox's follower-ceiling count, which a
  refused read would have answered with 0, is preceded by a one-row read with
  `authorize_with: :error`; a refusal or a failed count is treated as "at the
  ceiling", and the follow is refused and logged. Honest senders see no
  difference unless the nonce store is down. (#1659)

<a id="mix-kilnmigrationscheck-gates-expand-contract"></a>

- **`mix kiln.migrations.check` fails a PR whose new migration breaks the
  release still serving mid-deploy.** From 1.0 schema changes follow an
  expand → migrate → contract policy across releases, written out in
  [`docs/releasing.md`](../releasing.md#migrations-expand-migrate-contract):
  add nullable or defaulted, backfill outside the migration, and drop, rename
  or tighten only in a later release. The task reads each migration a PR adds
  (core and overlay directories, forward direction only) and flags dropped or
  renamed tables and columns, type changes (resolved from `from:` or the
  migration history), `NOT NULL` without a default or a backfill release,
  destructive raw SQL, non-concurrent indexes on large tables, and a
  concurrent index inside a transaction. A deliberate contract step carries a
  `# kiln:contract-ok since vX.Y.Z — <reason>` marker naming the shipped
  release that stopped reading the old shape. It runs in the `build` CI job on
  pull requests. The existing history is exempt; judged whole, it would have
  flagged 106 statements, among them
  `20260919191545_drop_webhook_plaintext_secret`. The same section of
  `docs/releasing.md` says what zero-downtime does and does not cover.
  Operators are unaffected.
  ([#1716](https://github.com/The-Verscienta/kiln_cms/issues/1716))
<a id="mint-1110-closes-three-advisories-http1-response-smuggling-and-two-http2"></a>

- **`mint` 1.11.0 closes three advisories: HTTP/1 response smuggling and two
  HTTP/2 client memory exhaustions (EEF-CVE-2026-91043 HIGH, -92103, -94194).**
  All three were published against `mint` 1.10.1 on 2026-09-28 and fixed in
  1.11.0. A malicious HTTP/2 server could make the client decode HPACK-indexed
  `cookie` fields far past `max_header_list_size`, which is enforced only on
  the compressed block (EEF-CVE-2026-91043, HIGH). It could also hold up to
  about 16 MiB per connection in a frame larger than `max_frame_size`, which is
  checked only once the whole payload has arrived (EEF-CVE-2026-92103). A
  malicious HTTP/1 server could send `Transfer-Encoding: chunked, gzip`, which
  Mint framed as chunked although RFC 9112 reads such a body to connection
  close. That desynchronizes Mint from a strict intermediary on a pooled
  connection (EEF-CVE-2026-94194). Kiln reaches Mint through Req and Finch on
  every outbound HTTP path, and webhooks, ActivityPub federation and media URL
  import aim at hosts an operator or editor supplies, so a hostile origin is
  reachable. `mint` is transitive only, so this is a one-line `mix.lock`
  change.
