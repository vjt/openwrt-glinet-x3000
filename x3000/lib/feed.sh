# x3000/lib/feed.sh — shared checks and helpers for the public apk feed
# at https://vjt.github.io/x3000-feed/ (kmods per release tag + rolling
# custom packages). Sourced by prepare.sh, release.sh, publish-feed.sh
# and x3000/tests/, so that every check exists in exactly one place.
# "Cutting a release" in x3000/README.md has the workflow.
#
# Everything here fails closed: a helper that cannot prove its check
# passed calls feed_die. Callers run with `set -euo pipefail` and call
# these functions as plain statements (set -e is suspended inside
# conditions, and in every function they call).

FEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Overridable so the tests can point them at fixtures. prepare.sh bakes
# FEED_BASE_URL into the image and release.sh checks the image against
# its own value, so a stray override fails the artifact check.
: "${FEED_BASE_URL:=https://vjt.github.io/x3000-feed}"
: "${FEED_GIT_URL:=git@github.com:vjt/x3000-feed.git}"
: "${FEED_GH_REPO:=vjt/x3000-feed}"
: "${FEED_KEY_REPO:=vjt/x3000-feed-key}"
: "${RELEASE_GH_REPO:=vjt/openwrt-glinet-x3000}"
: "${FEED_HOST_BIN:=$FEED_ROOT/staging_dir/host/bin}"
: "${FEED_TIMEOUT:=600}"
: "${FEED_POLL_INTERVAL:=5}"

FEED_ARCH=aarch64_cortex-a53
FEED_KEEP_TAGS=3
FEED_KEEP_VERSIONS=2
FEED_IMAGE_PREFIX=openwrt-mediatek-filogic-glinet_gl-x3000
FEED_SYSUPGRADE_SUBDIR=sysupgrade-glinet_gl-x3000
FEED_LIST_NAME=x3000feed.list

feed_log() {
    echo "==> $*" >&2
}

feed_warn() {
    echo "WARNING: $*" >&2
}

feed_die() {
    echo "FATAL: $*" >&2
    exit 1
}

# Temp files go under $FEED_TMPDIR when the caller set one (release.sh
# and publish-feed.sh remove it on exit).
feed_mktemp() {
    mktemp -p "${FEED_TMPDIR:-${TMPDIR:-/tmp}}" "$@"
}

feed_hostbin() {
    local bin="$FEED_HOST_BIN/$1"
    [[ -x "$bin" ]] || feed_die "missing host tool $bin (build the tree once: host tools live in staging_dir/host/bin)"
    printf '%s\n' "$bin"
}

# The tree's apk (3.x), not whatever the host has.
feed_apk() {
    local apk
    apk="$(feed_hostbin apk)"
    "$apk" "$@"
}

# The tag becomes a URL path segment and a git ref.
feed_check_tag() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || feed_die "bad tag '${1:-}': letters, digits, '.', '_' and '-' only, not starting with '-' or '.'"
}

# The two feed lines an image built for <tag> carries in
# /etc/apk/repositories.d/x3000feed.list.
feed_repo_list() {
    local tag="$1" base="${2:-$FEED_BASE_URL}"
    printf '%s/kmods/%s/packages.adb\n' "$base" "$tag"
    printf '%s/custom/packages.adb\n' "$base"
}

# Normalised "<name> <url> <ref> <subdir>" lines of a custom-feeds list
# (x3000/custom-feeds.txt format): comments and blank lines dropped.
feed_list_entries() {
    local list="$1" raw_line line name url ref subdir
    [[ -f "$list" ]] || feed_die "missing $list"
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" ]] && continue
        read -r name url ref subdir <<< "$line"
        [[ -n "${subdir:-}" ]] || feed_die "malformed line in $list: $raw_line"
        printf '%s %s %s %s\n' "$name" "$url" "$ref" "$subdir"
    done < "$list"
}

# The `origin` the build records for packages of each list line:
# prepare.sh clones <url> into .build-deps/<repo-basename>/ and links
# <subdir> into feeds-local/. One per line, sorted, unique.
feed_custom_origins() {
    local entries name url ref subdir
    entries="$(feed_list_entries "$1")"
    while read -r name url ref subdir; do
        [[ -n "$name" ]] || continue
        printf '.build-deps/%s/%s\n' "$(basename "${url%.git}")" "$subdir"
    done <<< "$entries" | sort -u
}

# Release builds must be signed with private-key.pem: every image we
# ever shipped trusts its public half. Without it, package/Makefile
# silently mints a new key, and the feed signed with that one is
# UNTRUSTED on every device out there.
feed_check_key() {
    local root="$1" derived
    if [[ ! -f "$root/private-key.pem" ]]; then
        feed_die "$root/private-key.pem is missing: a release build would mint a new key that no shipped image trusts. Restore it:
    gh repo clone $FEED_KEY_REPO /tmp/x3000-feed-key
    cp /tmp/x3000-feed-key/private-key.pem /tmp/x3000-feed-key/public-key.pem '$root/'"
    fi
    [[ -f "$root/public-key.pem" ]] || feed_die "$root/public-key.pem is missing (restore it from $FEED_KEY_REPO)"
    derived="$(openssl ec -in "$root/private-key.pem" -pubout 2>/dev/null)" \
        || feed_die "$root/private-key.pem is not a readable EC private key"
    [[ "$derived" == "$(cat "$root/public-key.pem")" ]] \
        || feed_die "$root/public-key.pem does not derive from $root/private-key.pem"
}
