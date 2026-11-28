# 0096. Client keys are HMAC'd under a key derived from SECRET_KEY_BASE

- **Status** — accepted (2026-11-28).
- **References** — [#3501](https://github.com/The-Verscienta/kiln_cms/issues/3501)
  (HMAC the stored client keys), which this closes;
  [#1619](https://github.com/The-Verscienta/kiln_cms/issues/1619) (the shared
  throttle table, threat-model residual 10);
  [#3504](https://github.com/The-Verscienta/kiln_cms/issues/3504) (a cap on the
  sightings one network can create), which it does not;
  [ADR 0095](0095-a-search-engine-claim-nothing-can-prove-counts-toward-the-404-guard-only-on-evidence-a-real-crawler-cannot-produce.md)
  (the crawler sightings table).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Security ([long form](../changelog/unreleased.md#client-key-hmac)) and
  Upgrade notes ([long form](../changelog/unreleased.md#client-key-hmac-upgrade)).

## The problem

Two tables store a key derived from a client: `throttle_counters.key_hash`
(`KilnCMS.Accounts.ThrottleStore`, every shared auth budget, tally and
scanner-guard counter) and `crawler_sightings.key_hash`
(`KilnCMS.Security.CrawlerSightingStore`). Both held `SHA-256(key)`. The keys
come from small spaces: `"inet:203.0.113.5"`, `"<org>|1.2.3.4/32"`, a raw
address, or `KilnCMS.Accounts.AccountThrottle.digest/1`, an unsalted SHA-256
of a lowercased email. Hashing every IPv4 address, or a list of known emails,
reverses a row in minutes, so a `pg_dump`, a backup or an unscrubbed staging
clone named the addresses that had been signing in, missing pages or being
rate-limited, and the accounts that had been attacked.

The digest must also keep what #1619 bought: one key lands on one row on
every node, so N nodes do not give an attacker N budgets. And it is needed
exactly when the database is not there: `ThrottleStore.Local`, the node-local
fallback used while Postgres cannot answer, keys its entries by the same
digest.

## Decision

**A client key is stored as an HMAC-SHA256 under a 32-byte key derived from
`SECRET_KEY_BASE` with a fixed label of its own, and both tables go through
one function to get it: `KilnCMS.Keys.ClientDigest.digest/1`.**

- **The key.** `Plug.Crypto.KeyGenerator.generate/3` from the endpoint's
  `secret_key_base` (read through `KilnCMS.Keys.Vault.secret_key_base/0`) and
  the label `"kiln client key digest v1"`, cached per node in
  `Plug.Crypto.Keys`. The label keeps it apart from every other key derived
  from the same secret, as `KilnCMS.Keys.Vault` and
  `KilnCMS.Accounts.SignInUnlock.address_digest/1` already do.
- **Why this secret.** It is the same on every node, so one key still lands
  on one row cluster-wide. It is never written to the database, so a dump or
  backup does not carry it, and a staging clone that runs its own (as
  [Staging environments](../staging-environments.md) asks) cannot match the
  rows it copied. It needs no database, so the fallback hashes the same way.
- **One function.** `ThrottleStore.key_hash/1` and
  `CrawlerSightingStore.key_hash/1` both call `ClientDigest.digest/1`. Every
  statement in those stores hashes through them.
- **What it is not.** To someone holding the secret a row is still a pseudonym
  a guessed key can be tested against; this is not encryption. No other stored
  hash changes: API keys, tokens and codes are high-entropy and keep their
  SHA-256, and `AccountThrottle.digest/1` stays as it is (it only ever reaches
  a table through the HMAC, and changing it would split every account budget
  a second time).
- **Rotation is a hard cutover.** `PREVIOUS_SECRET_KEY_BASE` is not read.
  After a rotation every budget, tally, active sign-in pause and sighting
  starts again on a new row, and the old rows lapse through `expires_at`.
  Changing the label is a rotation.

## Rejected

- **Documenting the SHA-256 as pseudonymous and leaving it.** It names every
  row to anyone with a dump and an afternoon.
- **The raw `SECRET_KEY_BASE` as the HMAC key.** A derived key with its own
  label is what every other user of the secret does; using the secret itself
  would tie this digest to every other purpose it serves.
- **A new environment variable.** One more secret to generate, back up,
  rotate and keep equal on every node, for a key `SECRET_KEY_BASE` already
  provides.
- **A random key stored in the database, under the vault.** The vault's key
  derives from `SECRET_KEY_BASE` anyway; reading it would put a database read
  on the sign-in hot path, it would be missing exactly when the fallback needs
  it, two nodes could race to create it on first boot, and it would sit in
  the same dump it is meant to protect against.
- **A per-node or per-boot key.** One budget per node again, which is what
  #1619 removed, and every restart would forgive everything.
- **An HMAC computed in SQL (`pgcrypto`).** The secret would travel to the
  database with every statement, and the fallback has no database.
- **A per-row salt, or truncating the digest.** A salt per row makes the
  upsert unable to find the row; truncation weakens the digest and saves
  nothing in a 32-byte column.
- **A read window under `PREVIOUS_SECRET_KEY_BASE`, or charging both
  digests.** It would double every charge on the hot path to soften a
  one-window effect at a rotation the operator chooses.
- **A migration that deletes or rewrites the old rows.** The old keys cannot
  be recomputed from their hashes, and deleting them resets every active
  lockout at a moment an attacker can observe; letting them lapse costs
  nothing.

## Consequences

- A `throttle_counters` or `crawler_sightings` row in a dump, backup or clone
  names nobody without production's `SECRET_KEY_BASE`. The staging scrub
  still purges both tables.
- **The rolling deploy that introduced it splits budgets, once.** While nodes
  on the plain SHA-256 and nodes on the HMAC run side by side, one key is
  counted on two rows. Every budget admits up to twice its limit per window
  for the windows the mixed period covers (up to 20 more password guesses per
  account per 15-minute window; about 10 rather than 5 mails an hour), an
  alert window may send one duplicate mail, and the failed-sign-in alert
  tally may undercount for one window. It is bounded, it ends one window of
  the longest budget (six hours) after the last old node stops, and an
  attacker collects it just by retrying through refusals. A single node
  restarted onto the new release resets each budget once instead. Rolling
  back is the same, in reverse. No migration.
- **A rolling rotation of `SECRET_KEY_BASE` splits the same way, at every
  rotation**, and a rotation is often part of an incident response. A
  single-step rotation resets every budget and active sign-in pause instead.
  [Secrets rotation](../secrets-rotation.md#secret_key_base) says so.
- A new table that stores a client-derived key should call
  `ClientDigest.digest/1` rather than hash it itself.
