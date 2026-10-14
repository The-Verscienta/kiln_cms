#!/usr/bin/env bash
# A plugin installed through the overlay's `config/project_deps.exs` (#1967)
# must build into the core without changing a file the core commits.
#
# Installs `sdk/fixtures/project_dep_plugin` through the hook, never through
# mix.exs, then checks that:
#
#   * the plugin compiled into the core (the check fails with the hook removed);
#   * its Hex dependency was locked in `config/project.lock`, which was seeded
#     with every `mix.lock` entry, and `mix.lock` is byte-identical;
#   * `git status` is unchanged: both files are git-ignored;
#   * `mix kiln.plugins.doctor` names the plugin as installed but not
#     registered in `config :kiln_cms, :plugins`.
#
# Run from anywhere, under MIX_ENV=test. Both overlay files are removed on
# every exit; the script refuses to start if either already exists, rather
# than clobber a real overlay's.
set -euo pipefail

cd "$(dirname "$0")/../.."
export MIX_ENV=test

deps_file=config/project_deps.exs
lock_file=config/project.lock

for f in "$deps_file" "$lock_file"; do
  if [ -e "$f" ]; then
    echo "::error::$f already exists; this check would overwrite an overlay's file"
    exit 1
  fi
done

cleanup() {
  rm -f "$deps_file" "$lock_file"
  rm -rf "_build/$MIX_ENV/lib/kiln_project_dep_fixture" "_build/$MIX_ENV/lib/recase" deps/recase
  # Leave the build matching the core alone for whatever runs next.
  mix compile >/dev/null 2>&1 || true
}
trap cleanup EXIT

lock_before="$(shasum mix.lock)"
status_before="$(git status --porcelain)"

cat >"$deps_file" <<'DEPS'
[{:kiln_project_dep_fixture, path: "sdk/fixtures/project_dep_plugin"}]
DEPS

mix deps.get
mix compile

loaded="$(mix run --no-start -e 'IO.puts(Code.ensure_loaded?(KilnProjectDepFixture.Plugin))' | tail -n 1)"
if [ "$loaded" != "true" ]; then
  echo "::error::A plugin listed in $deps_file did not compile into the core (loaded: $loaded). Is mix.exs still appending KilnCMS.Config.ProjectDeps.deps/1?"
  exit 1
fi

if [ "$(shasum mix.lock)" != "$lock_before" ]; then
  echo "::error::mix.lock changed; an overlay's dependencies must lock into $lock_file"
  git --no-pager diff --stat mix.lock
  exit 1
fi

if ! grep -q '"recase":' "$lock_file"; then
  echo "::error::$lock_file has no entry for the plugin's Hex dependency (recase)"
  exit 1
fi

# Seeded from mix.lock: every core entry is there, unchanged.
missing="$(grep -o '^  "[a-z0-9_]*":.*' mix.lock | grep -vxF -f <(grep -o '^  "[a-z0-9_]*":.*' "$lock_file") || true)"
if [ -n "$missing" ]; then
  echo "::error::$lock_file is missing or changed core entries from mix.lock:"
  echo "$missing"
  exit 1
fi

# Compared with before, not required empty, so it runs on a working tree too.
if [ "$(git status --porcelain)" != "$status_before" ]; then
  echo "::error::Installing an overlay dependency changed the core checkout:"
  diff <(echo "$status_before") <(git status --porcelain) || true
  exit 1
fi

doctor="$(mix kiln.plugins.doctor 2>&1)"
if ! grep -q 'KilnProjectDepFixture.Plugin' <<<"$doctor"; then
  echo "::error::mix kiln.plugins.doctor did not report the unregistered project_deps plugin:"
  echo "$doctor"
  exit 1
fi

echo "OK: a plugin installed through $deps_file built into the core, locked into $lock_file, and left the checkout unchanged."
