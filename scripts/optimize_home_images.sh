#!/usr/bin/env bash
#
# optimize_home_images.sh — derive the shipped home-page images (#2165).
#
#   ./scripts/optimize_home_images.sh            # screenshots + default logo
#   ./scripts/optimize_home_images.sh home       # screenshots only
#   ./scripts/optimize_home_images.sh logo       # default logo variants only
#   ./scripts/optimize_home_images.sh docs       # every guide's screenshots (#2158, #2460)
#   ./scripts/optimize_home_images.sh docs editorial-workflow   # one guide's
#
# This is the ONLY path to the files under priv/static/images/home/ and the
# logo-mark-sm.* variants; never copy a raw capture into priv/static.
#
#   e2e/screenshots/raw/{editor,content,calendar,media}.jpg   (2880x1800, from
#       e2e/screenshots/home.spec.js; gitignored, never served)
#     -> priv/static/images/home/<name>-720.webp, <name>-1440.webp
#        (+ editor-2880.webp for the hero's 2x-on-HiDPI candidate)
#        priv/static/images/home/<name>.jpg   (1440w fallback for old browsers)
#
#   priv/static/images/logo-mark.png (278x379, left untouched)
#     -> priv/static/images/logo-mark-sm.png, logo-mark-sm.webp (88x120)
#
#   e2e/screenshots/raw/<guide>/<n>-<name>.jpg   (from the guide's capture
#       spec, e2e/screenshots/<guide>.spec.js; gitignored)
#     -> docs/images/<guide>/<n>-<name>.webp (at most 1440 wide), for
#        docs/<guide>.md. With no guide named, every folder under raw/ is
#        derived. Not part of `all`: the guides' images are not the site's, and
#        nothing under priv/static comes from them.
#        test/kiln_cms/docs/guide_images_test.exs holds the budgets.
#
# Tools:
#   cwebp    WebP encoder — `brew install webp` / `apt install webp`
#   sips     (macOS, preinstalled) OR ImageMagick 7 `magick` / ImageMagick 6
#            `convert` + `identify`, for the JPEG/PNG resizes. Picked in that
#            order; OPTIMIZE_RESIZER=sips|magick|convert forces one.
#
# OPTIMIZE_IMAGES_ROOT (default: the repo root) moves every input and output
# under another directory, so a test can run this without touching the
# committed images. The byte budgets in the page tests check the committed
# output; the `optimize_images_script` CI job runs
# scripts/ci/check_optimize_images.sh against both ImageMagick versions
# (#2461), which only checks what the resizer drives.
set -euo pipefail

ROOT="${OPTIMIZE_IMAGES_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RAW="$ROOT/e2e/screenshots/raw"
IMAGES="$ROOT/priv/static/images"
HOME_OUT="$IMAGES/home"
WEBP_Q="${WEBP_QUALITY:-80}"
JPG_Q="${JPEG_QUALITY:-78}"

die() { echo "optimize_home_images: $*" >&2; exit 1; }
warn() { echo "optimize_home_images: $*" >&2; }

command -v cwebp >/dev/null || die "cwebp not found (brew install webp / apt install webp)"

if [ -n "${OPTIMIZE_RESIZER:-}" ]; then
  RESIZER="$OPTIMIZE_RESIZER"
elif command -v sips >/dev/null; then
  RESIZER=sips
elif command -v magick >/dev/null; then
  RESIZER=magick
elif command -v convert >/dev/null; then
  RESIZER=convert
else
  die "need sips (macOS) or ImageMagick (magick/convert) to resize"
fi

case "$RESIZER" in
  sips | magick) command -v "$RESIZER" >/dev/null || die "OPTIMIZE_RESIZER=$RESIZER but $RESIZER is not installed" ;;
  # ImageMagick 6 measures with a separate `identify` binary.
  convert)
    if ! command -v convert >/dev/null || ! command -v identify >/dev/null; then
      die "OPTIMIZE_RESIZER=convert needs ImageMagick 6's convert and identify"
    fi
    ;;
  *) die "OPTIMIZE_RESIZER must be sips, magick or convert, not '$RESIZER'" ;;
esac

# resize <in> <out> <width|-> <height|-> <jpeg|png> [quality]
resize() {
  local in="$1" out="$2" w="$3" h="$4" fmt="$5" q="${6:-}"
  case "$RESIZER" in
    sips)
      local args=(-s format "$fmt")
      [ "$fmt" = jpeg ] && args+=(-s formatOptions "$q")
      if [ "$h" != "-" ]; then args+=(--resampleHeight "$h"); else args+=(--resampleWidth "$w"); fi
      sips "${args[@]}" "$in" --out "$out" >/dev/null
      ;;
    *)
      local geom="${w}x"; [ "$h" != "-" ] && geom="x${h}"
      # JPEG: drop metadata. PNG: 8-bit RGBA like sips writes (ImageMagick
      # would otherwise pick a palette when the colors fit), and no tIME chunk
      # and no text chunk at all, so rerunning on the same input is
      # byte-identical. `date` alone drops only date:create/date:modify, and
      # a run that crossed a second boundary still differed (#2585).
      local qa=() dst="$out"
      if [ "$fmt" = jpeg ]; then
        qa=(-quality "$q" -strip)
      else
        qa=(-define "png:exclude-chunks=date,time,tEXt,zTXt,iTXt")
        dst="PNG32:$out"
      fi
      "$RESIZER" "$in" -resize "$geom" "${qa[@]}" "$dst"
      ;;
  esac
}

home() {
  mkdir -p "$HOME_OUT"
  for name in editor content calendar media; do
    local src="$RAW/$name.jpg"
    [ -f "$src" ] || die "missing $src — run the capture first (e2e/screenshots/home.spec.js)"
    local widths="720 1440"
    [ "$name" = editor ] && widths="720 1440 2880"
    for w in $widths; do
      cwebp -quiet -q "$WEBP_Q" -m 6 -resize "$w" 0 "$src" -o "$HOME_OUT/$name-$w.webp"
    done
    resize "$src" "$HOME_OUT/$name.jpg" 1440 - jpeg "$JPG_Q"
  done
}

# image_width <file> — pixel width, with whichever tool resizes. `[0]` reads
# the first frame only; without it ImageMagick prints one width per frame.
image_width() {
  local w
  case "$RESIZER" in
    sips) w="$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')" ;;
    magick) w="$(magick identify -format '%w' "$1[0]")" ;;
    convert) w="$(identify -format '%w' "$1[0]")" ;;
  esac
  [[ "$w" =~ ^[0-9]+$ ]] || die "could not read the width of $1 with $RESIZER (got '$w')"
  echo "$w"
}

# docs [<guide>...] — derive the named guides' screenshots, or every guide's
# under raw/ when none is named.
docs() {
  local guide dir derived=()
  old_layout_hint
  if [ "$#" -gt 0 ]; then
    # Every name is checked before anything is written.
    for guide in "$@"; do
      guide_name_ok "$guide" || die "a guide is named like its docs/<guide>.md basename (lowercase letters, digits, '-' and '.'), not '$guide'"
    done
    for guide in "$@"; do
      docs_guide "$guide"
      derived+=("$guide")
    done
  else
    for dir in "$RAW"/*/; do
      [ -d "$dir" ] || continue
      guide="$(basename "$dir")"
      if ! guide_name_ok "$guide"; then
        warn "skipping $dir: not named like a docs/<guide>.md basename"
      elif ! has_file "$dir" '*.jpg'; then
        warn "skipping $dir: no .jpg in it"
      else
        docs_guide "$guide"
        derived+=("$guide")
      fi
    done
  fi
  # `${derived[@]}` of an empty array is an unbound variable to bash 3.2's `set -u`.
  [ "${#derived[@]}" -gt 0 ] || die "no $RAW/<guide>/*.jpg — run a guide's capture spec under e2e/screenshots/ first"

  for guide in "${derived[@]}"; do
    ( cd "$ROOT" && find "docs/images/$guide" -type f -name '*.webp' -exec ls -l {} + | awk '{print $5, $9}' )
  done
}

# The name becomes a path under docs/images/, as the guide's basename does
# (`roadmap-1.0` for docs/roadmap-1.0.md). It cannot start with a dot, so
# neither `.` nor `..` passes.
guide_name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; }

# Captures from before #2460 sat in raw/ itself as workflow-<n>-<name>.jpg.
old_layout_hint() {
  if has_file "$RAW" 'workflow-*.jpg'; then
    warn "$RAW/workflow-*.jpg is the old layout and is not read: move them to $RAW/editorial-workflow/ and drop the 'workflow-' prefix"
  fi
}

# has_file <dir> <glob> — whether the glob matches a file in dir.
has_file() {
  local src
  for src in "$1"/$2; do
    if [ -f "$src" ]; then return 0; fi
  done
  return 1
}

# docs_guide <guide> — raw/<guide>/*.jpg -> docs/images/<guide>/*.webp
docs_guide() {
  local guide="$1"
  local in="$RAW/$guide" out="$ROOT/docs/images/$guide"
  local found=0 src name w
  for src in "$in"/*.jpg; do
    [ -f "$src" ] || continue
    # Only once there is something to write, so a wrong name leaves no folder.
    [ "$found" = 1 ] || mkdir -p "$out"
    found=1
    name="$(basename "$src" .jpg)"
    w="$(image_width "$src")"
    [ "$w" -gt 1440 ] && w=1440
    cwebp -quiet -q "$WEBP_Q" -m 6 -resize "$w" 0 "$src" -o "$out/$name.webp"
  done
  [ "$found" = 1 ] || die "no $in/*.jpg — run e2e/screenshots/$guide.spec.js first"
}

logo() {
  local src="$IMAGES/logo-mark.png"
  [ -f "$src" ] || die "missing $src"
  resize "$src" "$IMAGES/logo-mark-sm.png" - 120 png
  cwebp -quiet -q 90 -m 6 -resize 88 120 "$src" -o "$IMAGES/logo-mark-sm.webp"
}

case "${1:-all}" in
  home) home ;;
  logo) logo ;;
  all) home; logo ;;
  docs) shift; docs "$@"; exit 0 ;;
  *) die "usage: $0 [home|logo|all] | $0 docs [<guide>...]" ;;
esac

( cd "$ROOT" && find priv/static/images -maxdepth 2 \( -name 'logo-mark-sm.*' -o -path '*/home/*' \) -type f -exec ls -l {} + | awk '{print $5, $9}' )
