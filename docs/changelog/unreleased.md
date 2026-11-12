# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.


## Fixed

<a id="release-eval-read-through"></a>

- **`bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'` runs again: release tasks under `eval` read through the content cache instead of crashing.**
  1.9's upgrade note asks operators to run `reserved_paths/0` in a release,
  and the documented `eval` form raised `ArgumentError` (no
  `:cachex_overseer_table`). `eval` starts only the repo
  (`Ecto.Migrator.with_repo/2`), and the audit's slug lookup reads through
  `KilnCMS.Cache`. Every task's `load_app` now turns the cache off when the
  app is not serving (`read_through_unless_serving/1`), so any `eval` task
  reads the database directly. Called over `rpc` on a running node, the live
  cache is untouched. Found on Verscienta's production upgrade to 1.9.2.
