# x3000/tests/lib/assert.sh — assertions for x3000/tests/run.sh.

FEED_LIB="$X3000_REAL_ROOT/x3000/lib/feed.sh"

fail() {
    echo "ASSERTION FAILED: $*" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]${3:+ ($3)}"
}

assert_contains() {
    grep -qF -- "$2" <<< "$1" || fail "expected to find [$2] in:"$'\n'"$1"
}

assert_not_contains() {
    if grep -qF -- "$2" <<< "$1"; then
        fail "did not expect [$2] in:"$'\n'"$1"
    fi
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file $1"
}

assert_no_file() {
    [[ ! -e "$1" ]] || fail "expected nothing at $1"
}

# Runs a snippet in a fresh bash with the lib sourced, so a feed_die or
# an implicit set -e exit inside it is a real exit and not swallowed by
# a condition. Exported variables reach it; fixture functions do not.
assert_ok() {
    local rc=0
    RUN_OUT="$(bash -O inherit_errexit -euo pipefail -c "source '$FEED_LIB'; $1" 2>&1)" || rc=$?
    (( rc == 0 )) || fail "expected success (rc=$rc) from: $1"$'\n'"$RUN_OUT"
}

assert_fails() {
    local rc=0
    RUN_OUT="$(bash -O inherit_errexit -euo pipefail -c "source '$FEED_LIB'; $1" 2>&1)" || rc=$?
    (( rc != 0 )) || fail "expected failure from: $1"$'\n'"$RUN_OUT"
    assert_contains "$RUN_OUT" "$2"
}
