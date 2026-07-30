<!--
Thanks for the PR. Keep the summary short; the checklists below are the parts
reviewers actually rely on. Delete any section that genuinely doesn't apply.
-->

## Summary

<!-- What changes and why, in a few sentences. -->

Closes #

## How to verify

<!-- The steps a reviewer should run: a test name, a route to visit, a curl. -->

## Quality gate

```bash
mix precommit
```

- [ ] `mix precommit` passes locally (compile-as-errors, format, credo, sobelow, deps.audit, plugins.doctor, tests)
- [ ] `mix ash.codegen --check` is clean — the resource change ships with its migration **and** snapshot, both hand-edit free
- [ ] Gettext catalogs don't drift — required for **any** edit to a file containing `gettext(...)`, including comments:
      `mix gettext.extract --merge && git diff --exit-code -- priv/gettext`
- [ ] `mix docs --warnings-as-errors` passes if this renamed a `docs/` file, changed a link between guides, or touched a moduledoc cross-reference
- [ ] `MIX_ENV=test mix dialyzer` passes — it's in CI but **not** in `mix precommit`

## Correctness

- [ ] New/changed actions are reachable through a **domain code interface** (`define :name, action: :name`), not raw `Ash.create!/read!`
- [ ] Every new resource has `Ash.Policy.Authorizer` and policies — a resource with no authorizer fails open, and the coverage guard will fail
- [ ] Tenant-scoped reads and writes pass a tenant; no bare `dynamic_all()` or default-org fallback
- [ ] Tests cover the new behaviour, including the authorization path (`can_*?` / `Ash.can?`)
- [ ] User-facing strings go through `gettext`

## Impact

- [ ] **No breaking change** to the overlay contract — no renamed/removed `KilnCMS.CMS.Content` extension point, `Kiln.Plugin` callback, or unmigrated block schema change. If there is one, [`CHANGELOG.md`](../CHANGELOG.md) gets an **Upgrading** section.
- [ ] Migrations are safe to run against an existing production database (no destructive or long-locking change without a note here)
- [ ] New public routes, sockets or outbound integrations are reflected in [`docs/threat-model.md`](../docs/threat-model.md)
- [ ] New env vars are documented in [`docs/environment-variables.md`](../docs/environment-variables.md) and `.env.example`
- [ ] New guides are listed in both `extras` and `groups_for_extras` in `mix.exs`

## Screenshots

<!-- Before/after for any UI change. Include dark mode if theming changed. -->
