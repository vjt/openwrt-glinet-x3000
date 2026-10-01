#!/usr/bin/env bash
#
# Stand-in for x3000/build.sh in the release.sh / publish-feed.sh tests
# (X3000_BUILD_CMD points here): same arguments, same outputs in
# miniature, driven by the FX_* knobs fx_build_outputs reads.
set -euo pipefail
shopt -s inherit_errexit
if [[ $# -ne 3 || "$1" != public || "$2" != --release ]]; then
    echo "fake-build: unexpected arguments: $*" >&2
    exit 2
fi
source "$X3000_REAL_ROOT/x3000/tests/lib/fixtures.sh"
fx_build_outputs "$FX_ROOT" "$3"
echo "build $*" >> "$TEST_TMP/build.log"
