#!/usr/bin/env bash
#
# x3000/publish-feed.sh custom [--dry-run] — refresh custom/ on the
# public apk feed without cutting a release: ship a quectel-5g-tools fix
# (bump its version first: published names are immutable) to every
# image already out there.
#
#   1/4 tree and key checks, continuity guard; newest tag from TAGS and
#       its released image from GitHub
#   2/4 build public in release mode for that tag
#   3/4 stage custom/ over the current gh-pages (kmods/ and TAGS stay as
#       published); the canary — the released image against the staged
#       feed — on localhost
#   4/4 publish; wait for Pages; the canary against the live feed
#   --dry-run stops after 3/4.
#
# Same host requirements and $X3000_BUILD_CMD as release.sh; every check
# lives in x3000/lib/feed.sh.

set -euo pipefail
shopt -s inherit_errexit

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/x3000/lib/feed.sh"

CUSTOM_SRC="$ROOT/bin/packages/$FEED_ARCH/custom"
: "${X3000_BUILD_CMD:=$ROOT/x3000/build.sh}"

usage() {
    echo "usage: $0 custom [--dry-run]" >&2
    exit 2
}

WORK="$(mktemp -d)"
FEED_TMPDIR="$WORK"
FEED_SERVE_PID=""
cleanup() {
    if [[ -n "$FEED_SERVE_PID" ]]; then
        kill "$FEED_SERVE_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

cmd_custom() {
    local dry=0 base tag image kver origins commit
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry=1
        shift
    fi
    [[ $# -eq 0 ]] || usage

    feed_log "1/4 tree and key checks"
    feed_check_tree "$ROOT" "$(( ! dry ))"
    feed_check_key "$ROOT"
    base="$(feed_clone_pages "$WORK/pages")"
    feed_continuity_check "$WORK/pages" "$ROOT"
    [[ -s "$WORK/pages/TAGS" ]] || feed_die "no tag published yet: cut a release with x3000/release.sh first"
    tag="$(awk 'NF { print; exit }' "$WORK/pages/TAGS")"
    feed_log "newest published tag: $tag"
    feed_fetch_release "$tag" "$WORK/release"
    image="$WORK/release/$FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin"
    kver="$(feed_manifest_kernel "$WORK/release/$FEED_IMAGE_PREFIX.manifest")"

    feed_log "2/4 build public --release $tag"
    # Unquoted on purpose: X3000_BUILD_CMD may carry a docker exec prefix.
    $X3000_BUILD_CMD public --release "$tag"

    feed_log "3/4 stage custom/ and check it on localhost"
    origins="$(feed_custom_origins "$ROOT/x3000/custom-feeds.txt")"
    feed_stage_custom_only "$WORK/pages" "$CUSTOM_SRC" "$origins" "$ROOT"
    feed_serve "$WORK/pages"
    feed_canary "$image" "$FEED_SERVE_URL" "$kver"
    if (( dry )); then
        feed_log "dry run OK: nothing was published"
        return 0
    fi

    feed_log "4/4 publish and verify the live feed"
    commit="$(feed_publish "$WORK/pages" "$base" "feed: custom/ refresh ($tag)")"
    feed_wait_pages_build "$commit"
    feed_wait_served "$FEED_BASE_URL" "$WORK/pages" custom/packages.adb
    feed_canary "$image" "$FEED_BASE_URL" "$kver"
    feed_log "custom/ is live"
}

case "${1:-}" in
    custom) shift; cmd_custom "$@" ;;
    *) usage ;;
esac
