# 0018. A site may only lower a deployment ceiling: refused on write, clamped on read

- **Status** — accepted (2026-11-08).
- **References** — [#2243](https://github.com/The-Verscienta/kiln_cms/issues/2243),
  following [#1133](https://github.com/The-Verscienta/kiln_cms/issues/1133)
  (`KilnCMS.Forms.EmbedCeiling`).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

Kiln has two ways for a per-site settings row to sit on top of the operator's
deployment-wide value, and a new settings resource has to pick one:

- **The site wins.** `KilnCMS.Accounts.PasswordPolicy` reads the site's
  `SitePasswordPolicy` row, then the operator's `BREACHED_PASSWORD_POLICY`, then
  the built-in default. The operator's value is only a default: a site can choose
  something looser or stricter.
- **The operator's value is a ceiling.** `KilnCMS.Forms.EmbedCeiling` (#1133):
  under `EMBED_ORIGINS_LOCKED`, a site's embed allowlist may narrow
  `EMBED_ORIGINS` but never widen it.

The per-class delivery budgets of #2243 (`KilnCMS.BotBudgets`) needed one of
the two. A budget is a share of the `:delivery` rate limit, so a higher value
spends the deployment's capacity: CPU, database connections and bandwidth that
every site on the installation shares.

## Decision

Bot budgets take the ceiling rule, in the EmbedCeiling shape:

- **The operator owns capacity.** The value in force for a class is
  `min(site, operator)`, where the operator's value is
  `KILN_BOT_BUDGET_*_PERCENT` or the built-in default. A site may lower a class;
  it may not raise one.
- **Refused on write.** A save that **changes** a column to more than the
  operator's value is refused (`KilnCMS.CMS.Validations.BotBudgetCeiling`). Only
  changing columns are checked, so a row written before the operator lowered
  their value can still be saved for its other columns.
- **Clamped on read.** `KilnCMS.BotBudgets` applies `min/2` every time, so a
  stored value above a since-lowered operator value is never a live widening.
  The console shows such a value as above what the server now allows.
- **An unreadable row reads as the operator's values,** never as something
  looser. A failure of the site's row can then only make a site's limits what
  the operator chose, not wider.

The validation message names the operator's number. EmbedCeiling's does not,
because its ceiling is a list of origins that could tell one site about
another's partners; a percentage per class says nothing about any site.

## How to choose for the next settings resource

Ask who bears the cost of a looser value.

- If it is the deployment (shared capacity, an outbound service the operator
  pays for, a header that weakens every site on the host), the operator's value
  is a ceiling: refuse a changing value above it on write, clamp on read, and
  fail to the operator's value.
- If it is the site alone (its own accounts' password stance, its own content
  policy), the site wins and the operator's value is only the default.

## Considered and rejected

- **Site wins, as for the password policy.** One site could raise its AI
  crawler ceiling to 1000% and spend capacity every other site on the node
  shares, on traffic anyone can produce by changing a header.
- **Refuse on write only.** A row saved under a higher operator value would keep
  that value after the operator lowered theirs, until someone re-saved the row.
- **Clamp on read only.** The admin would save 400% and see 100% in force, with
  no message saying why.
- **Re-validate every column on every save.** A site whose stored value went
  above a lowered operator value could not save any other class until it fixed
  that one.
