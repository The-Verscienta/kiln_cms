#!/usr/bin/env bash
#
# rehearse.sh — rehearse `mix kiln.update` from one past release to a candidate
# (#1540), the way a downstream overlay project really does it.
#
#   scripts/upgrade_rehearsal/rehearse.sh v0.8.0
#   CANDIDATE_REF=origin/main scripts/upgrade_rehearsal/rehearse.sh v0.8.0
#
# What it does, in order (each step logged to $WORK/<slug>/<step>.log):
#
#   setup       a local mirror of this repo plays "upstream", so nothing is
#               fetched from or pushed to GitHub. It carries two LOCAL-ONLY tags:
#               the candidate as the next minor's `-rc.0`, and a simulated final
#               release of it (the candidate with `## [Unreleased]` renamed to
#               the release heading, as the cut does).
#   downstream  a scratch project repo pinning the mirror as a submodule at FROM,
#               owning a copy of FROM's in-tree overlay (`projects/example`, or
#               `projects/acupuncture` before it) and its `config/project.exs` —
#               the project's own code, which the update leaves alone.
#   build_old   the image build, minus Docker: the pinned core, then the overlay
#               and its project.exs copied over it, its priv/ merged in.
#   seed_old    a FRESH database, FROM's migrations, FROM's own seeds and the
#               overlay's, then seed.exs: a page per shape a stored block tree
#               can hold (the legacy corpus), and a page and a post written by
#               FROM's own block code with every block type FROM knows.
#   notes       FROM's own `mix kiln.update --check`, against the simulated final
#               and against the rc, compared with the candidate's
#               `upgrade_notes/3` over the same changelog.
#   update      FROM's own `mix kiln.update --to <rc>` inside the submodule
#               (with `--allow-major` when FROM is an older major), and the
#               pin commit in the downstream repo.
#   build_new   the rebuild at the candidate with the downstream's UNCHANGED
#               overlay. If that overlay no longer compiles, the rehearsal says
#               so and carries on with the candidate's own example.
#   drift       the overlay drift check, and — as docs/overlay-contract.md tells
#               a downstream to — codegen for any drift it finds.
#   migrate     `mix ash.migrate`.
#   verify      boot and read everything back (verify.exs before), run
#               `mix kiln.blocks.backfill`, read it all back again (verify.exs
#               after: the same rendered text, every stored tree canonical).
#
# The database is `kiln_cms_test_rehearse_<tag>` (MIX_ENV=test with a
# MIX_TEST_PARTITION: the one database-name knob every release honours). It is
# created here and dropped on exit; nothing else on the server is touched.
#
# Environment:
#   CANDIDATE_REF     the candidate commit (default: HEAD of this checkout)
#   REHEARSAL_WORK    scratch root (default: a new mktemp dir)
#   STEP_TIMEOUT      seconds per step (default 1800)
#   KEEP=1            keep the scratch tree and database afterwards
#   POSTGRES_HOST / POSTGRES_USER / POSTGRES_PASSWORD   as for the test suite
#
# Exits non-zero when the upgrade fails; $WORK/<slug>/result.json says where,
# and lists the problems found on the way even when it passes.

set -uo pipefail

FROM="${1:?usage: rehearse.sh vX.Y.Z}"
HARNESS="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="$(cd "$HARNESS/../.." && pwd)"
CANDIDATE_REF="${CANDIDATE_REF:-HEAD}"
STEP_TIMEOUT="${STEP_TIMEOUT:-1800}"
WORK="${REHEARSAL_WORK:-$(mktemp -d -t kiln-rehearsal)}"

SLUG="rehearse_$(echo "$FROM" | tr '.-' '__')"
DIR="$WORK/$SLUG"
DS="$DIR/downstream"
BUILD="$DIR/build"
MIRROR="$WORK/mirror.git"
OVERLAY=""

export MIX_ENV=test
export MIX_TEST_PARTITION="_$SLUG"
# Strict (fail-closed) tenancy, as prod compiles it — and as CI's overlay_drift
# job does, whose snapshots are the prod schema. The plain test build is
# fail-open, and its codegen reads every foreign key as changed.
export KILN_STRICT_TEST=1
DB_NAME="kiln_cms_test$MIX_TEST_PARTITION"

rm -rf "$DIR"
mkdir -p "$DIR"
RESULT="$DIR/result.json"
STEPS=()
STATUS="pass"
PROBLEMS=()
NOTES_PRINTED=()
NOTES_EXPECTED=()

now() { date +%s; }
START_ALL=$(now)

log() { printf '[%s %s] %s\n' "$(date +%H:%M:%S)" "$FROM" "$*" >&2; }

# step NAME FUNCTION — run under the step timeout, logging to $DIR/NAME.log.
# `timeout` needs a program, so the function runs in a child bash that
# inherits it (every function and variable it uses is exported below).
step() {
  local name=$1 fn=$2 t0 rc
  t0=$(now)
  log "step $name"
  timeout "$STEP_TIMEOUT" bash -c "$fn" >"$DIR/$name.log" 2>&1
  rc=$?
  STEPS+=("{\"step\":\"$name\",\"rc\":$rc,\"seconds\":$(($(now) - t0))}")
  if [ $rc -ne 0 ]; then
    log "step $name FAILED (rc=$rc) — tail of $DIR/$name.log:"
    tail -n 40 "$DIR/$name.log" >&2
  fi
  return $rc
}

problem() {
  PROBLEMS+=("$1")
  log "PROBLEM: $1"
}

json_strings() {
  local out="" s
  for s in "$@"; do
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    out+="${out:+,}\"$s\""
  done
  echo "[$out]"
}

psql_admin() {
  PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql -h "${POSTGRES_HOST:-localhost}" \
    -U "${POSTGRES_USER:-postgres}" -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

finish() {
  local rc=$?
  if [ "${KEEP:-}" != "1" ]; then
    log "dropping $DB_NAME"
    psql_admin -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)" >/dev/null 2>&1
    rm -rf "$DS" "$BUILD"
  fi
  local steps
  steps=$(IFS=,; echo "${STEPS[*]:-}")
  cat >"$RESULT" <<JSON
{"from":"$FROM","candidate":"${CANDIDATE_SHA:-}","rc_tag":"${RC_TAG:-}","final_tag":"${FINAL_TAG:-}",
 "status":"$STATUS","seconds":$(($(now) - START_ALL)),"overlay":"$OVERLAY",
 "notes_printed":$(json_strings ${NOTES_PRINTED[@]+"${NOTES_PRINTED[@]}"}),
 "notes_expected":$(json_strings ${NOTES_EXPECTED[@]+"${NOTES_EXPECTED[@]}"}),
 "problems":$(json_strings ${PROBLEMS[@]+"${PROBLEMS[@]}"}),
 "steps":[$steps]}
JSON
  log "result: $STATUS ($(($(now) - START_ALL))s) → $RESULT"
  exit $rc
}
trap finish EXIT

fail() {
  STATUS="fail"
  problem "$1"
  exit 1
}

# ── setup ──────────────────────────────────────────────────────────────────

setup_mirror() {
  set -e
  # One mirror per work root, shared by every tag rehearsed into it.
  [ -d "$MIRROR" ] || git clone --quiet --mirror "$SRC_REPO" "$MIRROR"
  git -C "$MIRROR" fetch --quiet "$SRC_REPO" "+$CANDIDATE_SHA:refs/rehearsal/candidate"
  git -C "$MIRROR" tag -f "$RC_TAG" "$CANDIDATE_SHA" >/dev/null

  # The simulated final: the candidate's tree with the changelog cut the way
  # docs/releasing.md cuts it. Only CHANGELOG.md differs — it is all that
  # `kiln.update` reads the notes from.
  local blob tree commit
  blob=$(git -C "$MIRROR" show "$CANDIDATE_SHA:CHANGELOG.md" |
    awk -v h="## [${FINAL_TAG#v}] - $(date +%Y-%m-%d)" \
      '!done && /^## \[Unreleased\]/ { print h; done = 1; next } { print }' |
    git -C "$MIRROR" hash-object -w --stdin)
  tree=$(git -C "$MIRROR" ls-tree "$CANDIDATE_SHA" |
    awk -v b="$blob" -F'\t' '$2 == "CHANGELOG.md" { sub(/[0-9a-f]{40}/, b, $1) } { print $1 "\t" $2 }' |
    git -C "$MIRROR" mktree)
  commit=$(GIT_AUTHOR_NAME=rehearsal GIT_AUTHOR_EMAIL=rehearsal@localhost \
    GIT_COMMITTER_NAME=rehearsal GIT_COMMITTER_EMAIL=rehearsal@localhost \
    git -C "$MIRROR" commit-tree "$tree" -p "$CANDIDATE_SHA" -m "rehearsal: cut $FINAL_TAG")
  git -C "$MIRROR" tag -f "$FINAL_TAG" "$commit" >/dev/null
}

setup_downstream() {
  set -e
  mkdir -p "$DS"
  cd "$DS"
  git init --quiet .
  git -c protocol.file.allow=always submodule --quiet add "$MIRROR" upstream
  git -C upstream checkout --quiet --detach "$FROM"

  # The downstream's own overlay: whatever FROM shipped in-tree.
  local overlay=acupuncture
  [ -d upstream/projects/example ] && overlay=example
  mkdir -p projects config
  cp -R "upstream/projects/$overlay" "projects/$overlay"
  cp "projects/$overlay/project.exs" config/project.exs
  [ "$overlay" = example ] && repair_from_candidate "projects/example/priv/repo/migrations"
  dedupe_overlay_migrations "upstream/priv/repo/migrations" "projects/$overlay/priv/repo/migrations" "$overlay"

  git add -A
  git -c user.name=rehearsal -c user.email=rehearsal@localhost commit --quiet \
    -m "downstream pinned at $FROM"
}

# Example migrations shipped broken and corrected since, by version. A
# downstream that copied one had to fix it to migrate at all; the fix it makes
# is the candidate's file (same version, so Ecto sees the same migration).
# Taking it is reported (REPAIRED lines become problems). Only these: the
# example's other migrations changed shape across releases (0.6.0's still
# carried an acupuncture-era `conditions` type), so swapping in the
# candidate's copy of those would be a different overlay, not a fix.
#
#   20260815142530  0.7.0–0.11.0: altered `conditions`, a table the example
#                   never had, instead of `products`; also shared its name and
#                   module with the core's add_content_lifecycles (#1540).
REPAIRED_EXAMPLE_VERSIONS="20260815142530"

repair_from_candidate() {
  local dir=$1 path file version ours
  while IFS= read -r path; do
    file=$(basename "$path")
    version=${file%%_*}
    case " $REPAIRED_EXAMPLE_VERSIONS " in *" $version "*) ;; *) continue ;; esac
    for ours in "$dir/${version}"_*.exs; do
      [ -f "$ours" ] || continue
      if ! git -C "$MIRROR" show "$CANDIDATE_SHA:$path" | cmp -s - "$ours"; then
        rm "$ours"
        git -C "$MIRROR" show "$CANDIDATE_SHA:$path" >"$dir/$file"
        echo "REPAIRED $(basename "$ours") → the candidate's $file"
      fi
    done
  done < <(git -C "$MIRROR" ls-tree --name-only "$CANDIDATE_SHA" "projects/example/priv/repo/migrations/")
}

# Ecto refuses a migrations directory in which two files share a name, and the
# overlay's are merged into the core's. From 0.7.0 to 0.11.0 the example's
# `add_content_lifecycles` collided with the core's, so no example-activated
# build could migrate; a downstream that copied it had to rename its file.
# Do the same here — same timestamp, so Ecto sees the same migration — and say
# so (the step log's RENAMED lines become a problem in the result).
dedupe_overlay_migrations() {
  local core=$1 overlay_dir=$2 overlay=$3 file base version name module suffix
  [ -d "$overlay_dir" ] || return 0
  suffix="$(echo "${overlay:0:1}" | tr '[:lower:]' '[:upper:]')${overlay:1}"
  for file in "$overlay_dir"/*.exs; do
    base=$(basename "$file" .exs)
    version=${base%%_*}
    name=${base#*_}
    if ls "$core"/*_"$name".exs >/dev/null 2>&1; then
      module=$(sed -nE 's/^defmodule ([A-Za-z0-9_.]+) do.*/\1/p' "$file" | head -n 1)
      sed -i.bak -E "s/^defmodule $module do/defmodule $module$suffix do/" "$file" && rm -f "$file.bak"
      mv "$file" "$overlay_dir/${version}_${overlay}_$name.exs"
      echo "RENAMED $base → ${version}_${overlay}_$name ($module collides with the core's)"
    fi
  done
}

# The Dockerfile's PROJECT= activation, against a plain directory.
sync_build() {
  set -e
  mkdir -p "$BUILD"
  rsync -a --delete --exclude .git --exclude /deps --exclude /_build \
    "$DS/upstream/" "$BUILD/"
  rm -rf "$BUILD/projects/$OVERLAY"
  cp -R "$DS/projects/$OVERLAY" "$BUILD/projects/$OVERLAY"
  cp "$DS/config/project.exs" "$BUILD/config/project.exs"
  if [ -d "$BUILD/projects/$OVERLAY/priv" ]; then
    cp -R "$BUILD/projects/$OVERLAY/priv/." "$BUILD/priv/"
  fi
}

build() {
  set -e
  cd "$BUILD"
  mix deps.get
  mix compile
}

# ── seeding at FROM ────────────────────────────────────────────────────────

seed_old() {
  set -e
  cd "$BUILD"
  psql_admin -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)"
  mix ecto.create
  mix ash.migrate
  mix run priv/repo/seeds.exs

  # The overlay's own seeds, in the order its README gives. Before 0.7.0 the
  # import read an external Sanity export named on the command line; with no
  # such file to give it, it is skipped (and said so).
  local script path
  for script in field_definitions dynamic_types import demo_config; do
    path="projects/$OVERLAY/priv/repo/${OVERLAY}_${script}.exs"
    [ -f "$path" ] || continue
    if grep -q 'System.argv()' "$path"; then
      echo "REHEARSAL: skipped $path (it needs an export file)"
    else
      mix run "$path"
    fi
  done

  mix run "$HARNESS/seed.exs" "$DIR/corpus.json" "$DIR/manifest.json"
}

# ── the update ─────────────────────────────────────────────────────────────

# FROM's own task, run from the pinned checkout exactly as documented. It has
# `@requirements []` and shells out to nothing but git, so it is loaded straight
# from FROM's source instead of paying for a second, core-only compile of FROM.
old_kiln_update() {
  (cd "$DS/upstream" && elixir -e '
    Mix.start()
    Mix.shell(Mix.Shell.IO)
    Code.require_file("lib/mix/tasks/kiln.update.ex")
    Mix.Tasks.Kiln.Update.run(System.argv())
  ' -- "$@")
}

notes() {
  set -e
  old_kiln_update --check --to "$FINAL_TAG" >"$DIR/notes_final.txt" 2>&1
  old_kiln_update --check --to "$RC_TAG" >"$DIR/notes_rc.txt" 2>&1
  git -C "$MIRROR" show "$FINAL_TAG:CHANGELOG.md" >"$DIR/final_changelog.md"
  git -C "$MIRROR" show "$RC_TAG:CHANGELOG.md" >"$DIR/rc_changelog.md"
  # The candidate's own upgrade_notes/3 is the reference.
  git -C "$MIRROR" show "$RC_TAG:lib/mix/tasks/kiln.update.ex" >"$DIR/candidate_kiln_update.ex"
  elixir "$HARNESS/expected_notes.exs" "$DIR/candidate_kiln_update.ex" \
    "$DIR/final_changelog.md" "${FROM#v}" "${FINAL_TAG#v}" >"$DIR/notes_final_expected.txt"
  elixir "$HARNESS/expected_notes.exs" "$DIR/candidate_kiln_update.ex" \
    "$DIR/rc_changelog.md" "${FROM#v}" "${RC_TAG#v}" >"$DIR/notes_rc_expected.txt"
}

# v1.2.0-rc.0 → 1
major() { local v=${1#v}; echo "${v%%.*}"; }

# The release headings printed under "What this update asks of you" (`  0.9.0`).
printed_versions() {
  awk '/What this update asks of you/ { on = 1; next }
       on && /^  [0-9]+\.[0-9]+\.[0-9]+/ { print $1 }' "$1"
}

# Across a major boundary FROM's task refuses without `--allow-major`, by
# design: a major bump says the overlay contract broke. A downstream on 0.12
# moving to 1.x passes the flag once it has read the notes, so the rehearsal
# does too — the path past the guard is the one worth rehearsing. Every
# release since 0.5.0 accepts the flag.
update() {
  set -e
  local allow_major=()
  [ "$(major "$FROM")" -lt "$(major "$RC_TAG")" ] && allow_major=(--allow-major)
  old_kiln_update --to "$RC_TAG" ${allow_major[@]+"${allow_major[@]}"}
  cd "$DS"
  git add upstream
  git -c user.name=rehearsal -c user.email=rehearsal@localhost commit --quiet \
    -m "chore: update kiln to $RC_TAG"
}

# ── the candidate ──────────────────────────────────────────────────────────

drift() {
  cd "$BUILD" || return 1
  if mix ash.codegen --check; then
    echo "REHEARSAL: no overlay drift"
    return 0
  fi
  # docs/overlay-contract.md: a downstream generates its own migrations for
  # what a core macro change added to its tables. Any prompt (a DROP for a
  # table whose domain project.exs does not register) is declined.
  echo "REHEARSAL: overlay drift — generating the downstream's migrations"
  mix ash.codegen "rehearsal_upgrade_to_${RC_TAG//[.-]/_}" </dev/null || return 1
  mix ash.codegen --check
}

doctor() { cd "$BUILD" && mix kiln.plugins.doctor; }
migrate() { cd "$BUILD" && mix ash.migrate; }
verify_before() { cd "$BUILD" && mix run "$HARNESS/verify.exs" before "$DIR/manifest.json" "$DIR/render.json"; }
backfill() { cd "$BUILD" && mix kiln.blocks.backfill; }
verify_after() { cd "$BUILD" && mix run "$HARNESS/verify.exs" after "$DIR/manifest.json" "$DIR/render.json"; }

# ── main ───────────────────────────────────────────────────────────────────

CANDIDATE_SHA=$(git -C "$SRC_REPO" rev-parse --verify "$CANDIDATE_REF^{commit}") ||
  fail "unknown candidate ref $CANDIDATE_REF"
git -C "$SRC_REPO" rev-parse --verify --quiet "$FROM^{commit}" >/dev/null ||
  fail "no such tag $FROM"

# The next minor after the newest final release: v0.11.0 → v0.12.0.
LATEST=$(git -C "$SRC_REPO" tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
FINAL_TAG=${FINAL_TAG:-$(echo "$LATEST" | awk -F. '{ printf "%s.%d.0", $1, $2 + 1 }')}
RC_TAG=${RC_TAG:-$FINAL_TAG-rc.0}

export FROM HARNESS SRC_REPO WORK DIR DS BUILD MIRROR DB_NAME CANDIDATE_SHA FINAL_TAG RC_TAG REPAIRED_EXAMPLE_VERSIONS
export -f major psql_admin setup_mirror setup_downstream repair_from_candidate dedupe_overlay_migrations sync_build build seed_old old_kiln_update \
  notes update drift doctor migrate verify_before backfill verify_after

step setup setup_mirror || fail "could not set up the upstream mirror"
step downstream setup_downstream || fail "could not set up the downstream repo"
OVERLAY=acupuncture
[ -d "$DS/projects/example" ] && OVERLAY=example
export OVERLAY
while IFS= read -r line; do
  problem "the $OVERLAY overlay at $FROM cannot migrate beside its core: $line"
done < <(grep -E '^(RENAMED|REPAIRED)' "$DIR/downstream.log")

elixir -e '
  [corpus, out] = System.argv()
  Code.require_file(corpus)
  data = for {name, expectation, stored} <- KilnCMS.LegacyBlockCorpus.entries(),
             do: %{name: name, expectation: inspect(expectation), stored: stored}
  File.write!(out, JSON.encode!(data))
' "$SRC_REPO/test/support/legacy_block_corpus.ex" "$DIR/corpus.json" ||
  fail "could not export the legacy block corpus"

step sync_old sync_build || fail "could not assemble the build tree at $FROM"
step build_old build || fail "$FROM does not build with its own overlay"
step seed_old seed_old || fail "could not migrate and seed at $FROM"

if step notes notes; then
  while IFS= read -r v; do NOTES_PRINTED+=("$v"); done < <(printed_versions "$DIR/notes_final.txt")
  while IFS= read -r v; do NOTES_EXPECTED+=("$v"); done <"$DIR/notes_final_expected.txt"
  if [ "${NOTES_PRINTED[*]:-}" != "${NOTES_EXPECTED[*]:-}" ]; then
    STATUS="fail"
    problem "notes $FROM → $FINAL_TAG: printed [${NOTES_PRINTED[*]:-}], expected [${NOTES_EXPECTED[*]:-}]"
  fi
  rc_printed=$(printed_versions "$DIR/notes_rc.txt" | xargs)
  rc_expected=$(xargs <"$DIR/notes_rc_expected.txt")
  if [ "$rc_printed" != "$rc_expected" ]; then
    problem "notes $FROM → $RC_TAG: printed [$rc_printed], expected [$rc_expected]"
  fi
else
  STATUS="fail"
  problem "$FROM's kiln.update --check failed"
fi

step update update || fail "$FROM's kiln.update --to $RC_TAG failed"
step sync_new sync_build || fail "could not assemble the build tree at the candidate"

if ! step build_new build; then
  problem "the $OVERLAY overlay as shipped at $FROM does not compile against $RC_TAG (build_new.log)"
  # The downstream makes the code changes the notes ask for; the candidate's
  # in-tree example is what those look like. Carry on from there.
  rm -rf "${DS:?}/projects/$OVERLAY"
  OVERLAY=example
  export OVERLAY
  cp -R "$DS/upstream/projects/example" "$DS/projects/example"
  cp "$DS/projects/example/project.exs" "$DS/config/project.exs"
  step sync_new_example sync_build || fail "could not re-assemble the build tree"
  step build_new_example build || fail "the candidate does not build with its own example overlay"
fi

step drift drift || fail "overlay drift could not be resolved by codegen"
if grep -q "overlay drift — generating" "$DIR/drift.log"; then
  generated=$(find "$BUILD/priv/repo/migrations" -name '*rehearsal_upgrade*' | xargs -n1 basename 2>/dev/null | xargs)
  problem "overlay drift $FROM → $RC_TAG: the downstream had to generate migrations ($generated)"
fi

while IFS= read -r table; do
  problem "mix ash.codegen offered to DROP table $table (default yes; declined here) after $FROM → $RC_TAG"
done < <(sed -nE 's/.*Table ([a-z0-9_]+) no longer has a resource.*/\1/p' "$DIR/drift.log" | sort -u)

# docs/overlay-contract.md's other on-every-build check. Its findings are the
# downstream's to fix, so they are reported rather than failing the upgrade.
if ! step doctor doctor; then
  while IFS= read -r line; do
    problem "kiln.plugins.doctor after $FROM → $RC_TAG: ${line#  \* }"
  done < <(grep '^  \* ' "$DIR/doctor.log")
fi

step migrate migrate || fail "migrations failed at $RC_TAG"
step verify_before verify_before || fail "content does not read back after the update"

# The corpus deliberately holds rows the backfill must flag for a person
# (legacy_html it cannot carry over faithfully, a parked custom block), so a
# non-zero exit here is expected; verify.exs checks the findings are exactly those.
step backfill backfill
step verify_after verify_after || fail "content does not read back the same after mix kiln.blocks.backfill"

exit 0
