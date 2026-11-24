# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="condition-text-ops"></a>

- **Conditional fields can match text (#3270).** A **Show when** or **Required when** test in `/editor/fields` now offers **contains**, **does not contain**, **starts with** and **ends with** when it reads a text, URL or choice field: "show **Download notes** when **File URL** ends with `.pdf`". In a rule these are the operators `contains`, `not_contains`, `starts_with` and `ends_with`, each with a non-blank string `value`.
  - **Matching ignores case and surrounding spaces.** Both sides are trimmed, as for `eq`, and lowercased. The editor's evaluator and the server agree on non-ASCII text too (a Greek word-final sigma folds to ς on both); one shared fixture holds them to it.
  - **Lists and non-text values.** On a multiple field a test holds when any item matches, so **does not contain** holds only when no item contains the text. An empty value contains nothing. A number, yes/no or date field cannot use these tests: the definition is refused, and so is retyping a field to a non-text type while a text test reads it.
  - **Additive.** No migration. An older release reading a rule with one of these operators treats it as a rule it cannot read: the field is shown and not required, and the definition cannot be saved until the rule is changed.

## Changed

<a id="list-item-error-position"></a>

- **A list field's errors name an item one way, by its position as the list is stored, counting from 1 (#2683).** On a list custom field (a list of numbers, dates, links, …), a type error counted items from 1 (`item 2 must be a date (YYYY-MM-DD)`) while a value rule (`min`, `max`, a length, `pattern`, a color palette) named the item by its index from 0 inside the field's name (`Scores (scores[1]) must be at most 10`). One save could report the same item as 2 and as `[1]`.
  - **What a message says now.** Both kinds name the item as `Label (name) item N`: `Scores (scores) item 2 must be at most 10`. N is the item's position in the list as stored, counting from 1: one item per line, with blank items and dropped repeats left out. It is the same N whether the save, the editor's field error, the JSON:API `detail` or the GraphQL `message` shows it.
  - **Type errors can name a lower N.** A list that drops repeats (every core list type but numbers, and a plugin type whose `unique_items?/0` is `true`) used to count a repeat before the bad item; it no longer does. `["2026-03-01", "2026-03-01", "soon"]` on a date list now reports `item 2`, not `item 3`. This holds for `mix kiln.fields.convert` reports too, which coerce each item as a save would. What is stored is unchanged: the first occurrence of a repeat stays, as before.
  - **Groups and flexible fields still count from 0.** A group row's sub-field (`dosages[2].unit`) and a flexible field's block (`sections[2]._type`) keep their 0-based paths in the message.
  - **API clients.** Only the human-readable text changed, and error text is not among the surfaces `docs/api.md` lists as stable ("Versioning & stability"). JSON:API still answers `code` `invalid_attribute` with `source.pointer` `/data/attributes/custom_fields` and no `meta`; GraphQL still answers `code` `invalid_attribute` with `fields` `["custom_fields"]`. A client that parsed `name[i]` out of the text should read `item N` instead, and subtract 1 for an index.
  - **French and Spanish.** The value-rule message is translated (`élément 2`, `elemento 2`), but type errors are not yet translated, so one list can show both `item` and `élément` (or `elemento`). Translating type errors is [#3324](https://github.com/The-Verscienta/kiln_cms/issues/3324).
  - **No migration; rolling the pin back is safe.** An older release writes the old messages again.

## Fixed

<a id="api-key-unknown-scope"></a>

- **An API key whose scope this release doesn't know loads, and authenticates as nothing (#2604).** A key's `access` scope was a plain atom column, so a key minted by a newer release with a scope this one lacks (met on an older node during a rolling deploy, or after a rollback) failed every read that touched it: the key's own lookup at sign-in, the whole list at `/editor/api-keys`, revoking it, revoking an erased account's keys (erasure, the erasure backfill) and revoking a squatter's keys on invitation takeover. `access` is now a `KilnCMS.Types.KnownAtom`, as `docs/releasing.md` ("New values in an atom column") asks of a column that will grow, so the key loads with its scope as `%UnknownAtom{}`, and all of those work again.
  - **Refused, never read-only.** A new scope may grant less than read, so such a key must not fall back to its owner's reads. `User.valid_api_keys` admits only the scopes this release knows (`KilnCMS.Accounts.ApiKey.Scope.known/0`), so the key is refused exactly as a revoked one: the same `401` on JSON:API, GraphQL, `/mcp`, `GET /api/feed`, `GET /api/graphql/schema.graphql` and `POST /api/keys/rotate`, and anonymous on the bridge socket. Nothing is logged on the refusal: the key is simply not found, and logging it would cost an extra read on the unauthenticated path. That filter is the only gate for now; the drafts-only read clamps match `:draft_write` exactly, and hardening them is [#3316](https://github.com/The-Verscienta/kiln_cms/issues/3316).
  - **Rotation reuse still counts.** A rotated-away key presented more than 120 seconds after its rotation still revokes its chain, whatever its scope reads as; a live unknown-scope key with no successor is refused and burns nothing.
  - **In the console.** `/editor/api-keys` lists the key as **Unrecognized scope (name)**, with the stored name, and status **Not accepted** (an expired one reads **Expired**, as does an erased owner's). The status's tooltip says a release that knows the scope accepts it again, so revoke it if that isn't wanted. **Revoke** works as for any key.
  - **Security posture.** `core.api_keys` counts such keys in a new fact, `unrecognized_scope_keys`, and is **Review** for them, never **Fix now**; they are also named in **Details** when the check fails for an administrator's read-write key. `valid_keys` now counts only the keys that sign in on this release. During a rollout that adds a scope, older nodes warn and newer ones pass, and the JSON endpoint caches each node's answer for up to 30 seconds. The posture JSON contract is additive, so the new fact is not a breaking change.
  - **No migration; rolling the pin back is safe.** The column stays text. Mint keys with a new scope only once every node runs the release that added it; see `docs/releasing.md`.

<a id="beta-round-seat-audited"></a>

- **A new beta-round seat records its role grant, and an admin seat raises the new-admin alert (#2641).** `mix kiln.beta.round` wrote each new seat's account straight to the database with its role already set, so the security log had no `role_granted` for it and an admin seat raised no platform `new_admin` alert. An operator round mints admins, and on a shared beta or staging instance they appeared with no trace in the log and no word to the platform admins. An address that already had an account was handled correctly; only new seats were missed.
  - **What a new seat records now.** The account is still created pre-confirmed with a generated password and no mail, but at the default `viewer` role; its tier is then set through `User` `:manage_access`, the same action an adopted account and the **Accounts** page go through. The default site's log gets one `role_granted` with `level` `platform`, no person, and `previous_role` `viewer`. That `viewer` is the account's starting role for an instant inside the same transaction, never a role anyone signed in with.
  - **Alerts.** Each admin seat (the facilitator of an authoring round, every tester of an operator round) raises the platform `new_admin` alert to the platform admins. An editor seat raises no alert, as a platform role raised short of admin never does.
  - **One transaction per seat.** Creating a seat's account and granting its tier commit together: if the grant fails, the task raises and leaves no account for that seat. Seats made earlier in the same run stay, and their passwords are not printed because the task stops before the handout; re-run with `--reset-passwords` to issue them, which re-issues every existing seat's password, so not once testers are signed in.
  - **Still not recorded.** The first admin made at `/setup`, accounts from `priv/repo/seeds.exs` and the staging admin a scrub creates write no role event; `docs/security-events.md` ("Not recorded, and why") says why for each.
  - **No migration; rolling the pin back is safe.** An older release creates seats the old way again.
