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

# fx_key DIR: a fresh prime256v1 key pair, named like the tree's.
fx_key() {
    mkdir -p "$1"
    openssl ecparam -name prime256v1 -genkey -noout -out "$1/private-key.pem" 2>/dev/null
    openssl ec -in "$1/private-key.pem" -pubout -out "$1/public-key.pem" 2>/dev/null
}

# fx_prepare_tree DIR: a tree in which prepare.sh and build.sh run end
# to end without network or toolchain — a copy of the real x3000/ with
# no custom feeds and no patches, a stub scripts/feeds, and a stub make
# on PATH that logs its arguments and creates any BIN_DIR= it is given.
fx_prepare_tree() {
    local dir="$1"
    mkdir -p "$dir/x3000" "$dir/scripts" "$TEST_TMP/stubbin"
    cp -a "$X3000_REAL_ROOT/x3000/." "$dir/x3000/"
    rm -rf "$dir/x3000/files-private" "$dir/x3000/patches"
    rm -f "$dir/x3000"/*.local
    mkdir -p "$dir/x3000/files-private"
    printf '# no custom feeds in fixtures\n' > "$dir/x3000/custom-feeds.txt"
    printf '#!/bin/sh\nexit 0\n' > "$dir/scripts/feeds"
    chmod +x "$dir/scripts/feeds"
    cat > "$TEST_TMP/stubbin/make" <<'STUB'
#!/bin/sh
echo "make $*" >> "$TEST_TMP/make.log"
for a in "$@"; do
    case "$a" in BIN_DIR=*) mkdir -p "${a#BIN_DIR=}" ;; esac
done
STUB
    chmod +x "$TEST_TMP/stubbin/make"
    export PATH="$TEST_TMP/stubbin:$PATH"
}
