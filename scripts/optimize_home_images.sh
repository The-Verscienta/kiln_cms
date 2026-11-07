#!/usr/bin/env bash
#
# optimize_home_images.sh — derive the shipped home-page images (#2165).
#
#   ./scripts/optimize_home_images.sh            # screenshots + default logo
#   ./scripts/optimize_home_images.sh home       # screenshots only
#   ./scripts/optimize_home_images.sh logo       # default logo variants only
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
# Tools:
#   cwebp    WebP encoder — `brew install webp` / `apt install webp`
#   sips     (macOS, preinstalled) OR ImageMagick `magick`/`convert`, for the
#            JPEG/PNG resizes
# CI does not run this; the byte budgets in the page tests check the
# committed output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="$ROOT/e2e/screenshots/raw"
IMAGES="$ROOT/priv/static/images"
HOME_OUT="$IMAGES/home"
WEBP_Q="${WEBP_QUALITY:-80}"
JPG_Q="${JPEG_QUALITY:-78}"

die() { echo "optimize_home_images: $*" >&2; exit 1; }

command -v cwebp >/dev/null || die "cwebp not found (brew install webp / apt install webp)"

if command -v sips >/dev/null; then
  RESIZER=sips
elif command -v magick >/dev/null; then
  RESIZER=magick
elif command -v convert >/dev/null; then
  RESIZER=convert
else
  die "need sips (macOS) or ImageMagick (magick/convert) to resize"
fi

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
      local qa=(); [ "$fmt" = jpeg ] && qa=(-quality "$q" -strip)
      "$RESIZER" "$in" -resize "$geom" ${qa[@]+"${qa[@]}"} "$out"
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
  *) die "usage: $0 [home|logo|all]" ;;
esac

( cd "$ROOT" && find priv/static/images -maxdepth 2 \( -name 'logo-mark-sm.*' -o -path '*/home/*' \) -type f -exec ls -l {} + | awk '{print $5, $9}' )
