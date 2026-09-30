# x3000/tests/lib/fixtures.sh — builders for what the tests need: keys,
# packages, images, feeds, remotes, a fake gh. Everything lives under
# $TEST_TMP, which run.sh creates per test and removes afterwards.

source "$X3000_REAL_ROOT/x3000/lib/feed.sh"

# The lib's temp files die with the test.
export FEED_TMPDIR="$TEST_TMP"

# Keep the user's git config (signing, hooks, default branch) out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

FX_KVER_DEFAULT='6.12.103~0123456789abcdef0123456789abcdef-r1'

# Background processes (http servers) to stop when the test exits.
FX_PIDS=()
fx_cleanup() {
    local p
    for p in "${FX_PIDS[@]}"; do
        kill "$p" 2>/dev/null || true
    done
}
trap fx_cleanup EXIT
