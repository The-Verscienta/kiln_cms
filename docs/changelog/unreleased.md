# KilnCMS Unreleased — full release notes

The long-form entries behind
[CHANGELOG.md → Unreleased](../../CHANGELOG.md#unreleased),
as they were written when each change merged. `CHANGELOG.md` carries the
one-line summary of each; this file carries the reasoning.

## Changed

<a id="changelogmd-is-a-summary-and-the-reasoning-moved-to-docschangelog-and"></a>

- **`CHANGELOG.md` is a summary, and the reasoning moved to
  `docs/changelog/` and `docs/decisions/`** (#1325). The file had reached 5,142
  lines across six releases, with entries written as design essays — one
  Unreleased security bullet ran thirty lines of threat-model prose. That is
  the wrong shape for the one moment it has to work: `mix kiln.update` shows it
  to an operator about to move a production pin, who is asking "what breaks if
  I upgrade?".

  Each release entry is now one line per change under **Upgrade notes**,
  **Breaking**, **Added**, **Changed**, **Fixed**, **Security** and
  **Removed** — 1,038 lines in total. Every line links to the pull request that
  shipped it and, where it was shortened, to its own long-form entry under
  `docs/changelog/`, which carries the original prose verbatim. Ten entries
  that argue a choice outliving their release became architecture decision
  records under `docs/decisions/`.

  New `mix kiln.changelog` does the work and keeps doing it. `--condense` moves
  the long form out and is idempotent, so it is a step in `docs/releasing.md`
  rather than a one-off migration; `--verify REF` proves, paragraph by
  paragraph, that nothing was dropped; `--check` runs in `mix precommit` and CI,
  holding Unreleased entries to three lines and failing on an entry with
  nowhere to link.

  `mix kiln.update` now prints only the **Upgrade notes** and **Breaking**
  sections between the two pins, with their long-form links rewritten to
  absolute URLs at the target tag. It still reads the `### Upgrading` spelling
  every release up to 0.8.0 used, since it reads the changelog at the tag being
  installed.

## Fixed

<a id="both-password-forms-check-the-confirmation-as-you-type"></a>

- **Both password forms check the confirmation as you type.** On `/register`
  and on the new-password page behind a reset link, the two password boxes
  disagreeing was held back until submit — which on registration also clears the
  password field, so a typo in the confirmation cost re-typing both.
  `KilnCMSWeb.AuthConfirmationFeedback` reveals that one error on `phx-change`;
  every other field — an empty email, an invalid reset token — stays quiet until
  submit, as before.

