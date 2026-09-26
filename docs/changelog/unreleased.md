# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Upgrade notes

<a id="a-new-throttlecounters-table-holds-the-auth-budgets-run-migrations-as"></a>

- **A new `throttle_counters` table holds the auth budgets; run migrations as
  usual.** `bin/migrate` (or the release's own migrate step) creates it. No
  configuration changes. The order does not matter on a rolling deploy: until
  the table exists, each node counts its budgets locally, as every release
  before this one did, and logs that it is doing so at most once a minute.
  Counts are not carried over from the old in-memory tables, so every budget
  starts empty on upgrade, exactly as it did after any restart. An Oban cron
  job in the `default` queue prunes closed windows every five minutes. (#1619)

## Fixed

<a id="a-429s-retry-after-is-rounded-up-never-0"></a>

- **A 429's `retry-after` is rounded up, never 0.** The per-IP rate limiter
  truncated the time left in its fixed window to whole seconds, so a client
  refused in the window's last second was told `retry-after: 0` and retried
  straight back into the closed window. The docs publisher honours the header:
  it spent all three retries within a few milliseconds and failed the v0.11.0
  docs sync a moment before the window reopened. The plug now rounds the same
  way `AccountThrottle.retry_after_seconds/1` already did for the second-factor
  budget — up, and never below one. `scripts/publish_docs.exs` also waits at
  least a second on any 429 and retries up to five times, since a full sync
  (~3 requests a guide) is larger than the `:api` bucket and keeps talking to
  sites that haven't picked this fix up.

## Security

<a id="auth-budgets-now-hold-across-nodes-and-restarts"></a>

- **Auth budgets now hold across nodes and restarts.** Every
  `AccountThrottle` budget (password sign-in, the TOTP and recovery-code
  budget, the reset and magic-link mail budgets, the owner alerts) and the
  credential rate-limit buckets (`:auth`, `:register`, `:unlock`) used to count
  in each node's ETS. On N nodes an attacker got N budgets, and a deploy forgave
  every attempt. They now count in one Postgres table through
  `KilnCMS.Accounts.ThrottleStore`: one `INSERT … ON CONFLICT DO UPDATE …
  RETURNING` per charge, keyed on a SHA-256 of the key, windowed on the
  database clock, and pruned by an Oban cron job. Measured locally, a charge
  costs 0.34 ms at p50 (1.1 ms at p50 with sixteen writers on one key), against
  the ~208 ms bcrypt verification the same sign-in already pays. Nothing is
  written to the user row, so an unknown address still throttles exactly like a
  known one. If the database cannot answer, a budget falls back to counting on
  the node, which is the old bound and never a weaker one. The fallback is
  logged. A charge made inside a transaction now raises instead of being
  silently refunded by a rollback. The registration budget is therefore charged
  in `before_transaction`, so a registration that fails on a taken address
  still pays. Flood-ceiling buckets (`:api`, `:delivery`, `:gql`, …) stay per
  node on purpose. This closes threat-model residual 10. (#1619)
