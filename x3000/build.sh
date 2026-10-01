#!/usr/bin/env bash
#
# x3000/build.sh — one-shot driver: prepare the tree for a variant,
# build, and relocate the artifacts under bin-x3000-<variant>/ so a
# subsequent build of the other variant doesn't clobber the output.
#
# Usage:  x3000/build.sh [private|public] [-- extra make args]
#
# Examples:
#   x3000/build.sh                  # private, default parallelism
#   x3000/build.sh public           # public, default parallelism
#   x3000/build.sh public -- V=s    # public, verbose make
#
# The build itself is just `make -j$(nproc)` with BIN_DIR pointing at a
# variant-specific output tree. OpenWrt honours BIN_DIR consistently
# across `bin/targets/...` and `bin/packages/...`, so private and public
# outputs never overwrite each other.

set -euo pipefail

VARIANT="${1:-private}"
case "$VARIANT" in
    private|public) ;;
    *)
        echo "usage: $0 [private|public] [-- extra make args]" >&2
        echo "  unknown variant: $VARIANT" >&2
        exit 2
        ;;
esac
shift || true
# Allow `-- foo bar` to forward extra make args verbatim.
if [[ "${1:-}" == "--" ]]; then shift; fi

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN_DIR="$ROOT/bin-x3000-$VARIANT"

"$ROOT/x3000/prepare.sh" "$VARIANT"

echo
echo "==> make -j$(nproc) BIN_DIR=$BIN_DIR $*"
make -j"$(nproc)" BIN_DIR="$BIN_DIR" "$@"

echo
echo "Done. variant=$VARIANT"
echo "Artifacts under: $BIN_DIR/targets/mediatek/filogic/"
