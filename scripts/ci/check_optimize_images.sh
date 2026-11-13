#!/usr/bin/env bash
#
# check_optimize_images.sh — run scripts/optimize_home_images.sh end to end
# in a scratch directory and check what its resizer produces (#2461).
#
#   scripts/ci/check_optimize_images.sh                         # first resizer found
#   OPTIMIZE_RESIZER=convert scripts/ci/check_optimize_images.sh  # ImageMagick 6
#   OPTIMIZE_RESIZER=magick scripts/ci/check_optimize_images.sh   # ImageMagick 7
#   OPTIMIZE_RESIZER=sips scripts/ci/check_optimize_images.sh     # macOS
#
# The inputs are real screenshots: the committed home-page WebPs, decoded
# with dwebp and scaled back to capture size (2880x1800) with the same
# resizer. Everything runs under OPTIMIZE_IMAGES_ROOT, a temporary directory,
# so the committed images are never overwritten.
#
# Checked, because the resizer drives it:
#   - home/<name>.jpg is 1440 wide, at most SIZE_BAND percent larger than the
#     committed (sips-made) one, and not under SIZE_FLOOR percent of it. One-
#     sided by decision (#2585): ImageMagick's quality scale differs from
#     sips', and at the same setting it writes JPEGs about 35-40% smaller;
#     smaller only lightens the page, so only a much LARGER file fails. The
#     floor is not a calibration, only a guard against a blank or broken
#     image, which a one-sided band would otherwise pass.
#   - logo-mark-sm.png is 88x120, 8-bit RGBA, like the committed one
#   - a second `logo` run writes a byte-identical logo-mark-sm.png
#   - docs: a 2000-wide capture becomes a 1440-wide WebP, a 1200-wide one
#     stays 1200 (the width comes from the script's image_width)
#   - docs: bare `docs` derives every raw/<guide>/ folder into
#     docs/images/<guide>/ (a `.` in the name included), skipping a badly
#     named or empty folder with a warning; `docs <guide>` only that one; a
#     guide with no captures, or one bad name among several, fails and writes
#     nothing; a bare run with nothing to derive fails; the pre-#2460
#     raw/workflow-*.jpg layout gets a hint (#2460)
# The WebP widths come from cwebp, whichever resizer runs, so they are only
# smoke-checked. PNG and WebP sizes are read from the PNG header (WebPs via
# dwebp), so no assertion depends on the tool under test measuring itself.
#
# Needs: cwebp, dwebp, od, and the resizer.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMITTED="$REPO/priv/static/images"
SIZE_BAND="${SIZE_BAND:-40}"
SIZE_FLOOR="${SIZE_FLOOR:-25}"

fail=0
die() { echo "check_optimize_images: $*" >&2; exit 1; }
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

for tool in cwebp dwebp od; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

if [ -z "${OPTIMIZE_RESIZER:-}" ]; then
  for r in sips magick convert; do
    if command -v "$r" >/dev/null; then OPTIMIZE_RESIZER=$r; break; fi
  done
fi
[ -n "${OPTIMIZE_RESIZER:-}" ] || die "no resizer found (sips, magick or convert)"
export OPTIMIZE_RESIZER
echo "resizer: $OPTIMIZE_RESIZER"
case "$OPTIMIZE_RESIZER" in
  magick) magick -version | head -1 ;;
  convert) convert -version | head -1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export OPTIMIZE_IMAGES_ROOT="$WORK/root"
RAW="$OPTIMIZE_IMAGES_ROOT/e2e/screenshots/raw"
OUT="$OPTIMIZE_IMAGES_ROOT/priv/static/images"
mkdir -p "$RAW" "$OUT" "$WORK/src"
cp "$COMMITTED/logo-mark.png" "$OUT/"

# to_jpg <in> <out> <width> — a high-quality JPEG capture at <width>.
to_jpg() {
  case "$OPTIMIZE_RESIZER" in
    sips) sips -s format jpeg -s formatOptions 92 --resampleWidth "$3" "$1" --out "$2" >/dev/null ;;
    *) "$OPTIMIZE_RESIZER" "$1" -resize "$3x" -quality 92 "$2" ;;
  esac
}

# jpg_width <file> — measured with the resizer's own tool; there is no
# header-only reader for JPEG here.
jpg_width() {
  case "$OPTIMIZE_RESIZER" in
    sips) sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}' ;;
    magick) magick identify -format '%w' "$1[0]" ;;
    convert) identify -format '%w' "$1[0]" ;;
  esac
}

# png_ihdr <file> — "width height bit-depth color-type" from the IHDR chunk.
png_ihdr() {
  od -An -v -tu1 -j16 -N10 "$1" | tr '\n' ' ' | awk '{print $1*16777216+$2*65536+$3*256+$4, $5*16777216+$6*65536+$7*256+$8, $9, $10}'
}

# webp_dims <file> — "width height", decoded to PNG first.
webp_dims() {
  local png="$WORK/probe.png"
  # A failed decode inside $(...) doesn't stop the script; removing the last
  # probe first means it can't hand back the previous image's size.
  rm -f "$png"
  dwebp -quiet "$1" -o "$png"
  png_ihdr "$png" | awk '{print $1, $2}'
}

bytes() { wc -c <"$1" | tr -d ' '; }

expect() { # expect <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1: want $2, got $3"; fi
}

# --- inputs ---------------------------------------------------------------
dwebp -quiet "$COMMITTED/home/editor-2880.webp" -o "$WORK/src/editor.png"
for name in content calendar media; do
  dwebp -quiet "$COMMITTED/home/$name-1440.webp" -o "$WORK/src/$name.png"
done
for name in editor content calendar media; do
  to_jpg "$WORK/src/$name.png" "$RAW/$name.jpg" 2880
done
# Two guides' captures, each in a folder named after its guide.
# A dotted name is a guide too; a badly named folder and an empty one are
# skipped; a capture in the old layout earns a hint.
mkdir -p "$RAW/editorial-workflow" "$RAW/second-guide" "$RAW/roadmap-1.0" "$RAW/Bad_Name" "$RAW/empty-guide"
to_jpg "$WORK/src/editor.png" "$RAW/editorial-workflow/1-wide.jpg" 2000
to_jpg "$WORK/src/content.png" "$RAW/editorial-workflow/2-narrow.jpg" 1200
to_jpg "$WORK/src/media.png" "$RAW/second-guide/1-shot.jpg" 1200
to_jpg "$WORK/src/media.png" "$RAW/roadmap-1.0/1-shot.jpg" 800
to_jpg "$WORK/src/media.png" "$RAW/Bad_Name/1-shot.jpg" 800
to_jpg "$WORK/src/media.png" "$RAW/workflow-1-old.jpg" 800

# --- run ------------------------------------------------------------------
bash "$REPO/scripts/optimize_home_images.sh" home >/dev/null
bash "$REPO/scripts/optimize_home_images.sh" logo >/dev/null
bash "$REPO/scripts/optimize_home_images.sh" docs 2>"$WORK/docs.err"

# --- home -----------------------------------------------------------------
printf '%-14s %10s %10s\n' "file" "bytes" "committed"
for name in editor content calendar media; do
  got="$OUT/home/$name.jpg"
  base="$COMMITTED/home/$name.jpg"
  printf '%-14s %10s %10s\n' "$name.jpg" "$(bytes "$got")" "$(bytes "$base")"
done

for name in editor content calendar media; do
  got="$OUT/home/$name.jpg"
  expect "home/$name.jpg width" 1440 "$(jpg_width "$got")"
  size=$(bytes "$got")
  base=$(bytes "$COMMITTED/home/$name.jpg")
  lo=$((base * SIZE_FLOOR / 100))
  hi=$((base * (100 + SIZE_BAND) / 100))
  if [ "$size" -gt "$hi" ]; then
    bad "home/$name.jpg $size bytes, over $hi (committed $base + ${SIZE_BAND}%)"
  elif [ "$size" -lt "$lo" ]; then
    bad "home/$name.jpg $size bytes, under $lo (${SIZE_FLOOR}% of committed $base): blank or broken?"
  else
    ok "home/$name.jpg $size bytes, at most ${SIZE_BAND}% over $base"
  fi
  widths="720 1440"
  [ "$name" = editor ] && widths="720 1440 2880"
  for w in $widths; do
    expect "home/$name-$w.webp width" "$w" "$(webp_dims "$OUT/home/$name-$w.webp" | awk '{print $1}')"
  done
done

# --- logo -----------------------------------------------------------------
expect "logo-mark-sm.png width height depth color-type" "88 120 8 6" "$(png_ihdr "$OUT/logo-mark-sm.png")"
expect "logo-mark-sm.webp size" "88 120" "$(webp_dims "$OUT/logo-mark-sm.webp")"
cp "$OUT/logo-mark-sm.png" "$WORK/logo-first.png"
bash "$REPO/scripts/optimize_home_images.sh" logo >/dev/null
if cmp -s "$WORK/logo-first.png" "$OUT/logo-mark-sm.png"; then
  ok "logo-mark-sm.png is byte-identical on a second run"
else
  bad "logo-mark-sm.png changed between two runs on the same input"
fi

# --- docs -----------------------------------------------------------------
docs="$OPTIMIZE_IMAGES_ROOT/docs/images"
expect "docs editorial-workflow/1-wide.webp width (capped)" 1440 "$(webp_dims "$docs/editorial-workflow/1-wide.webp" | awk '{print $1}')"
expect "docs editorial-workflow/2-narrow.webp width (kept)" 1200 "$(webp_dims "$docs/editorial-workflow/2-narrow.webp" | awk '{print $1}')"
expect "docs second-guide/1-shot.webp width (kept)" 1200 "$(webp_dims "$docs/second-guide/1-shot.webp" | awk '{print $1}')"
expect "docs roadmap-1.0/1-shot.webp width (kept)" 800 "$(webp_dims "$docs/roadmap-1.0/1-shot.webp" | awk '{print $1}')"
if [ ! -e "$docs/Bad_Name" ] && [ ! -e "$docs/empty-guide" ] &&
  grep -q "skipping .*Bad_Name" "$WORK/docs.err" && grep -q "skipping .*empty-guide" "$WORK/docs.err"; then
  ok "docs skips a badly named and an empty raw/ folder, with a warning"
else
  bad "docs did not skip raw/Bad_Name/ and raw/empty-guide/ with a warning: $(cat "$WORK/docs.err")"
fi
if grep -q "old layout.*raw/editorial-workflow/" "$WORK/docs.err"; then
  ok "docs hints at moving raw/workflow-*.jpg"
else
  bad "docs gave no hint for raw/workflow-*.jpg: $(cat "$WORK/docs.err")"
fi

# A named guide is derived alone.
rm -rf "$docs"
bash "$REPO/scripts/optimize_home_images.sh" docs second-guide >/dev/null
if [ -f "$docs/second-guide/1-shot.webp" ] && [ ! -e "$docs/editorial-workflow" ]; then
  ok "docs second-guide derives that guide only"
else
  bad "docs second-guide did not derive exactly docs/images/second-guide/"
fi

# A guide with no captures is an error, not an empty folder.
if bash "$REPO/scripts/optimize_home_images.sh" docs no-such-guide >/dev/null 2>&1; then
  bad "docs no-such-guide succeeded"
elif [ -e "$docs/no-such-guide" ]; then
  bad "docs no-such-guide failed but left docs/images/no-such-guide/"
else
  ok "docs no-such-guide fails and leaves no folder"
fi

# One bad name among several fails before any guide is derived.
rm -rf "$docs"
if bash "$REPO/scripts/optimize_home_images.sh" docs second-guide Bad_Name >/dev/null 2>&1; then
  bad "docs second-guide Bad_Name succeeded"
elif [ -e "$docs/second-guide" ]; then
  bad "docs second-guide Bad_Name failed but derived second-guide first"
else
  ok "docs second-guide Bad_Name fails before deriving anything"
fi

# A bare run with nothing it can derive fails.
if OPTIMIZE_IMAGES_ROOT="$WORK/empty-root" bash -c 'mkdir -p "$OPTIMIZE_IMAGES_ROOT/e2e/screenshots/raw/Bad_Name" && "$0" docs' "$REPO/scripts/optimize_home_images.sh" >/dev/null 2>&1; then
  bad "a bare docs run with nothing to derive succeeded"
else
  ok "a bare docs run with nothing to derive fails"
fi

if [ "$fail" = 0 ]; then
  echo "check_optimize_images: all checks passed with $OPTIMIZE_RESIZER"
else
  die "some checks failed with $OPTIMIZE_RESIZER"
fi
