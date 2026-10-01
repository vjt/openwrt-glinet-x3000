#!/usr/bin/env bash
#
# x3000/build.sh — one-shot driver: prepare the tree for a variant,
# build, and put the image artifacts under bin-x3000-<variant>/.
#
# Usage:  x3000/build.sh [private|public] [--release <tag>] [-- extra make args]
#
# Examples:
#   x3000/build.sh                           # private, default parallelism
#   x3000/build.sh public                    # public, default parallelism
#   x3000/build.sh public -- V=s             # public, verbose make
#   x3000/build.sh private --release jeeves-r9
#
# The build is `make -j$(nproc)` with BIN_DIR pointing at
# bin-x3000-<variant>/, which receives the images and the target
# packages (kmods, kernel, base-files, …) directly — not under
# targets/. Feed packages (base, packages, luci, custom, …) still land in
# the shared bin/packages/<arch>/<feed>/, so building one variant
# overwrites the other's feed packages there.
#
# Release mode (--release <tag>) is what x3000/release.sh uses:
#   - prepare.sh --release refuses to run without private-key.pem and
#     points the image at the public apk feed for <tag>;
#   - bin-x3000-<variant>/ and bin/packages/ are wiped before make.
#     package/compile runs on every make and each .apk is a file target,
#     so everything is re-packed (not recompiled): afterwards the output
#     dirs hold exactly this build, and neither the image (whose rootfs
#     installs from every .apk in them) nor the feed sees a stale file;
#   - <tag> is recorded in bin-x3000-<variant>/FEED_TAG.
# Without --release nothing is wiped, the image does not point at our
# feed, and the build signs with its own auto-generated key.

set -euo pipefail
shopt -s inherit_errexit

VARIANT="private"
RELEASE_TAG=""
MAKE_ARGS=()

usage() {
    echo "usage: $0 [private|public] [--release <tag>] [-- extra make args]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        private|public) VARIANT="$1"; shift ;;
        --release)
            [[ $# -ge 2 ]] || usage
            RELEASE_TAG="$2"
            shift 2
            ;;
        --) shift; MAKE_ARGS=("$@"); break ;;
        *)
            echo "  unknown argument: $1" >&2
            usage
            ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN_DIR="$ROOT/bin-x3000-$VARIANT"

if [[ -n "$RELEASE_TAG" ]]; then
    # prepare.sh runs first: it refuses a missing key before we wipe.
    "$ROOT/x3000/prepare.sh" "$VARIANT" --release "$RELEASE_TAG"
    echo "==> release mode: wiping $BIN_DIR and $ROOT/bin/packages"
    rm -rf "$BIN_DIR" "$ROOT/bin/packages"
else
    "$ROOT/x3000/prepare.sh" "$VARIANT"
fi

echo
echo "==> make -j$(nproc) BIN_DIR=$BIN_DIR ${MAKE_ARGS[*]}"
make -j"$(nproc)" BIN_DIR="$BIN_DIR" "${MAKE_ARGS[@]}"

if [[ -n "$RELEASE_TAG" ]]; then
    echo "$RELEASE_TAG" > "$BIN_DIR/FEED_TAG"
fi

echo
echo "Done. variant=$VARIANT${RELEASE_TAG:+ release=$RELEASE_TAG}"
echo "Artifacts under: $BIN_DIR/"
