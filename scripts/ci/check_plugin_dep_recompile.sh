#!/usr/bin/env bash
# An edit to a plugin shipped as a Mix dependency must reach the registries the
# core bakes at compile time, with a plain `mix compile` — no `--force` (#1909).
#
# Mix does not track compile-time edges into a dependency's modules, so without
# `Kiln.Plugins.__mix_recompile__?/0` the dependency recompiles and the core
# keeps the old `blocks/0`: the new block is in `KilnCMS.Blocks.registry/0`
# (read at runtime) but not in `KilnCMS.CMS.TypedBlocks`' type table (a module
# attribute, baked at compile time), so a stored one comes back as
# `KilnCMS.Blocks.Custom`. This adds `KilnDepFixture.Ribbon` to the fixture
# plugin's `blocks/0`, recompiles, and asks that table. (Not
# `BlockUnion.subtype_constraints/0`: `Ash.Type.NewType` evaluates its
# constraints at runtime, so it would pass with no recompile at all.)
#
# The same for a field type's list capability (#2680): `KilnCMS.CMS.FieldTypes`
# bakes `multiple?/0` at compile time, so turning it off on the fixture's
# `Stars` must take `:stars` out of `ClearMultiple.list_types/0`.
#
# Run from anywhere, under MIX_ENV=test (the fixture is a `:test` dependency and
# config/test.exs registers it). The fixture files are restored on every exit.
set -euo pipefail

cd "$(dirname "$0")/../.."
export MIX_ENV=test

file=sdk/fixtures/dep_plugin/lib/kiln_dep_fixture/plugin.ex
backup="$(mktemp)"
cp "$file" "$backup"

stars=sdk/fixtures/dep_plugin/lib/kiln_dep_fixture/field_types/stars.ex
stars_backup="$(mktemp)"
cp "$stars" "$stars_backup"

restore() {
  cp "$backup" "$file"
  cp "$stars_backup" "$stars"
  rm -f "$backup" "$stars_backup"
  # Leave the build matching the restored source for whatever runs next.
  mix compile >/dev/null 2>&1 || true
}
trap restore EXIT

# Prints true/false: does the compile-time type table know `dep_ribbon`?
in_union() {
  mix run --no-start -e \
    'IO.puts(match?([%{__struct__: KilnDepFixture.Ribbon}], KilnCMS.CMS.TypedBlocks.to_typed([%{"_type" => "dep_ribbon", "text" => "x"}])))' |
    tail -n 1
}

mix compile
before="$(in_union)"
if [ "$before" != "false" ]; then
  echo "::error::KilnDepFixture.Ribbon is already a known block type before the edit ($before); the check proves nothing"
  exit 1
fi

perl -pi -e 's/def blocks, do: \[KilnDepFixture\.Badge\]/def blocks, do: [KilnDepFixture.Badge, KilnDepFixture.Ribbon]/' "$file"
if ! grep -q 'KilnDepFixture.Badge, KilnDepFixture.Ribbon' "$file"; then
  echo "::error::Could not rewrite blocks/0 in $file; update this script with the fixture"
  exit 1
fi

# Plain compile, as an author editing a path-dependency plugin would run it.
mix compile
after="$(in_union)"
if [ "$after" != "true" ]; then
  echo "::error::An edit to a dependency plugin's blocks/0 did not reach KilnCMS.CMS.TypedBlocks without --force (got: $after). See Kiln.Plugins.__mix_recompile__?/0."
  exit 1
fi

echo "OK: a dependency plugin's new block reached the compile-time block registries without --force."

# Prints true/false: may a `:stars` field be a list?
stars_listable() {
  mix run --no-start -e \
    'IO.puts(:stars in KilnCMS.CMS.Changes.ClearMultiple.list_types())' |
    tail -n 1
}

before="$(stars_listable)"
if [ "$before" != "true" ]; then
  echo "::error:::stars is not a list type before the edit ($before); the check proves nothing"
  exit 1
fi

perl -pi -e 's/def multiple\?, do: true/def multiple?, do: false/' "$stars"
if ! grep -q 'def multiple?, do: false' "$stars"; then
  echo "::error::Could not rewrite multiple?/0 in $stars; update this script with the fixture"
  exit 1
fi

mix compile
after="$(stars_listable)"
if [ "$after" != "false" ]; then
  echo "::error::Turning off a dependency field type's multiple?/0 did not reach ClearMultiple.list_types/0 without --force (got: $after). See Kiln.Plugins.__mix_recompile__?/0."
  exit 1
fi

echo "OK: a dependency field type's list capability reached the compile-time registries without --force."
