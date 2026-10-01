#!/usr/bin/env bash
#
# x3000/tests/run.sh — hermetic tests for the release tooling:
# x3000/lib/feed.sh, the release mode of prepare.sh/build.sh,
# release.sh and publish-feed.sh.
#
# No network: packages, images, the gh-pages remote, "GitHub Pages" and
# gh itself are local fixtures (x3000/tests/lib/fixtures.sh). The tests
# do need the tree's host tools (staging_dir/host/bin: apk, unsquashfs4,
# mksquashfs4, fwtool), so build the tree once first, plus git, jq,
# curl, openssl, rsync and python3 on the host.
#
# Usage: x3000/tests/run.sh [test-file-glob] [test-function-regex]
#   x3000/tests/run.sh                       # everything
#   x3000/tests/run.sh 'test_lib_*'          # the lib only
#   x3000/tests/run.sh test_release.sh dry   # matching functions

set -euo pipefail
shopt -s inherit_errexit

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
X3000_REAL_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
FEED_HOST_BIN="${FEED_HOST_BIN:-$X3000_REAL_ROOT/staging_dir/host/bin}"
# Byte-order sort/ls everywhere, so expected listings do not depend on
# the caller's locale.
export LC_ALL=C
export X3000_REAL_ROOT FEED_HOST_BIN

for tool in apk unsquashfs4 mksquashfs4 fwtool; do
    if [[ ! -x "$FEED_HOST_BIN/$tool" ]]; then
        echo "missing $FEED_HOST_BIN/$tool: build the tree once first" >&2
        exit 2
    fi
done

file_glob="${1:-test_*.sh}"
fn_regex="${2:-.}"
pass=0
failed=()

# Unquoted on purpose: the first argument is a glob.
for file in "$TESTS_DIR"/$file_glob; do
    [[ -f "$file" ]] || continue
    # A file that does not even load must fail the run, not vanish from
    # it; a regex selecting nothing in a loadable file is fine.
    load_rc=0
    load_err="$(mktemp)"
    declared="$(bash -c "source '$file' && declare -F" 2>"$load_err")" || load_rc=$?
    if (( load_rc != 0 )); then
        failed+=("$(basename "$file") (cannot load)")
        echo "FAIL $(basename "$file") (cannot load)"
        sed 's/^/    /' "$load_err"
        rm -f "$load_err"
        continue
    fi
    rm -f "$load_err"
    fns="$(awk '$3 ~ /^test_/ { print $3 }' <<< "$declared" | grep -E -- "$fn_regex" || true)"
    for fn in $fns; do
        tmp="$(mktemp -d)"
        # A fresh bash per test: set -e is live in the test body, and a
        # feed_die inside it ends that test only.
        if out="$(cd "$tmp" && TEST_TMP="$tmp" bash -O inherit_errexit -euo pipefail -c "
                source '$TESTS_DIR/lib/assert.sh'
                source '$TESTS_DIR/lib/fixtures.sh'
                source '$file'
                $fn" 2>&1)"; then
            pass=$((pass + 1))
            echo "PASS $(basename "$file") $fn"
        else
            failed+=("$(basename "$file") $fn")
            echo "FAIL $(basename "$file") $fn"
            sed 's/^/    /' <<< "$out"
        fi
        rm -rf "$tmp"
    done
done

echo
if (( pass + ${#failed[@]} == 0 )); then
    echo "no tests matched"
    exit 1
fi
echo "$pass passed, ${#failed[@]} failed"
if (( ${#failed[@]} )); then
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
