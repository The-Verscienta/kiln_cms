#!/usr/bin/env bash
#
# build_bash32.sh — build GNU bash 3.2.57, the bash macOS ships as /bin/bash,
# into PREFIX (#2479).
#
#   scripts/ci/build_bash32.sh PREFIX
#
# The `backup_scripts_portability` job in ci.yml puts PREFIX/bin first on the
# test run's PATH, so `mix test test/scripts` drives the backup and restore
# scripts with the oldest bash they claim to support. The runner's bash is
# 5.x, and a feature 3.2 lacks (`$BASHPID`, `${var,,}`, `declare -A`, `wait
# -n`, an empty array under `set -u`) would otherwise only ever fail on a
# Mac.
#
# Supply chain. The tarball is pinned by SHA-256 below and nothing is run
# from it until the hash matches; a mirror serving other bytes fails the
# step. The pin was taken from ftp.gnu.org, its detached signature checked
# with gpgv against the GNU keyring (good signature, Chet Ramey, key
# 7C0135FB088AAF6C66C650B9BB5869F064EA74AB), and the hash cross-checked
# against mirrors.kernel.org. Because the hash is the trust anchor, the
# fallback mirror is as safe as the primary.
#
# The compiler flags. bash 3.2 is K&R-era C. GCC 14 turned implicit function
# declarations, implicit int, int conversions and incompatible pointer types
# into errors, and GCC 10 made -fno-common the default, which breaks 3.2's
# tentative definitions; `-std=gnu89` and the four `-Wno-` flags put the old
# rules back. The bundled malloc does not build on a modern glibc, readline is
# not needed for `bash -c` / scripts, and NLS would need gettext.
#
# Needs a C compiler, make, curl and bison. bison is not optional: the
# tarball's y.tab.c dates from 3.2's release in 2006, while the 57 patches
# folded into parse.y run to 2014 (the Shellshock parser fixes among them).
# make sees parse.y is newer and regenerates the parser; touching y.tab.c to
# skip that would build a bash without those fixes.
#
# Prints the built version; fails unless it starts with 3.2.57.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 PREFIX" >&2
  exit 2
fi

version=3.2.57
sha256=3fa9daf85ebf35068f090ce51283ddeeb3c75eb5bc70b1a4a7cb05868bfe06a4
tarball="bash-${version}.tar.gz"
urls=(
  "https://ftp.gnu.org/gnu/bash/${tarball}"
  "https://ftpmirror.gnu.org/bash/${tarball}"
)

for tool in cc make curl bison; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "::error::${tool} is not on PATH; building bash ${version} needs it" >&2
    exit 1
  }
done

mkdir -p "$1"
prefix="$(cd "$1" && pwd -P)"

work="$(mktemp -d "${TMPDIR:-/tmp}/kiln-bash32.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fetched=false
for url in "${urls[@]}"; do
  if curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 -o "$work/$tarball" "$url"; then
    actual="$(sha256_of "$work/$tarball")"
    if [ "$actual" = "$sha256" ]; then
      fetched=true
      break
    fi
    echo "::warning::${url} served ${tarball} with SHA-256 ${actual}, expected ${sha256}" >&2
  else
    echo "::warning::could not download ${url}" >&2
  fi
  rm -f -- "$work/$tarball"
done

if [ "$fetched" != true ]; then
  echo "::error::no mirror served ${tarball} with the pinned SHA-256" >&2
  exit 1
fi

tar -xzf "$work/$tarball" -C "$work"
cd "$work/bash-${version}"

CFLAGS="-O2 -std=gnu89 -fcommon -Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-incompatible-pointer-types" \
  ./configure --prefix="$prefix" --without-bash-malloc --disable-nls --disable-readline >/dev/null
# The binary alone: `make install` would also build the Info manual, which
# needs makeinfo, and the tests need nothing but `bash`.
make bash >/dev/null
mkdir -p "$prefix/bin"
install -m 0755 bash "$prefix/bin/bash"

# shellcheck disable=SC2016 # expanded by the built bash, not this one
built="$("$prefix/bin/bash" -c 'echo $BASH_VERSION')"
echo "built bash ${built} into ${prefix}"
case "$built" in
  "${version}"*) ;;
  *)
    echo "::error::${prefix}/bin/bash reports ${built}, expected ${version}" >&2
    exit 1
    ;;
esac
