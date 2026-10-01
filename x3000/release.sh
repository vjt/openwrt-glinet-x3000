#!/usr/bin/env bash
#
# x3000/release.sh — the only supported way to put artifacts on a
# GitHub release. It publishes the apk feed the image points at
# (https://vjt.github.io/x3000-feed/), proves that a device running the
# image can install kmods and our custom packages from it, and only
# then uploads the image. Nothing public is touched before step 6/7.
#
#   release.sh feed [--dry-run] <tag>
#     1/7 tree and key checks, continuity guard, released-tag guard
#     2/7 build public in release mode (clean outputs)
#     3/7 artifact check on the sysupgrade.bin itself
#     4/7 kernel consistency, refresh guard
#     5/7 stage gh-pages; the canary against it on localhost
#     6/7 publish (force-push gh-pages)
#     7/7 wait for Pages; the canary against the live feed; record the
#         artifact hashes in bin-x3000-public/.release-<tag>
#     --dry-run stops after 5/7 (the tree guard only warns) and records
#     nothing.
#
#   release.sh upload <tag> [--title <title> --notes-file <file>]
#     checks the artifacts against the record 'feed' wrote, re-runs the
#     canary against the live feed, then creates the release at the
#     recorded commit (a new tag needs --title and --notes-file) or
#     replaces the assets of an existing one. Uploads only from
#     bin-x3000-public/.
#
# Runs on the host: needs gh (push access to the feed repo), git, jq,
# curl, python3 and the tree's host tools. The build goes through
# $X3000_BUILD_CMD (default: x3000/build.sh); for a build container:
#   X3000_BUILD_CMD="docker exec -u builder -w /home/builder/openwrt <container> x3000/build.sh"
#
# Every check lives in x3000/lib/feed.sh and fails closed.

set -euo pipefail
shopt -s inherit_errexit

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/x3000/lib/feed.sh"

PUBLIC_BIN="$ROOT/bin-x3000-public"
PRIVATE_BIN="$ROOT/bin-x3000-private"
CUSTOM_SRC="$ROOT/bin/packages/$FEED_ARCH/custom"
: "${X3000_BUILD_CMD:=$ROOT/x3000/build.sh}"

usage() {
    echo "usage: $0 feed [--dry-run] <tag>" >&2
    echo "       $0 upload <tag> [--title <title> --notes-file <file>]" >&2
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

cmd_feed() {
    local dry=0 tag head base kver origins image commit
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry=1
        shift
    fi
    [[ $# -eq 1 ]] || usage
    tag="$1"
    feed_check_tag "$tag"

    feed_log "1/7 tree and key checks"
    feed_check_tree "$ROOT" "$(( ! dry ))"
    head="$(git -C "$ROOT" rev-parse HEAD)"
    feed_check_key "$ROOT"
    base="$(feed_clone_pages "$WORK/pages")"
    feed_continuity_check "$WORK/pages" "$ROOT"
    feed_check_new_tag "$WORK/pages" "$tag"

    feed_log "2/7 build public --release $tag"
    # A build that builds nothing must not pass step 3 on an earlier run's
    # outputs: FEED_TAG is written by this build or not at all.
    rm -f "$PUBLIC_BIN/FEED_TAG"
    # Unquoted on purpose: X3000_BUILD_CMD may carry a docker exec prefix.
    $X3000_BUILD_CMD public --release "$tag"

    feed_log "3/7 artifact check"
    feed_check_artifact "$PUBLIC_BIN" "$tag" "$ROOT"
    image="$(feed_sysupgrade_path "$PUBLIC_BIN")"

    feed_log "4/7 kernel consistency"
    kver="$(feed_manifest_kernel "$(feed_manifest_path "$PUBLIC_BIN")")"
    feed_check_kmods "$PUBLIC_BIN/packages" "$kver"
    feed_check_private_kernel "$PRIVATE_BIN" "$tag" "$kver"
    feed_check_refresh "$WORK/pages" "$tag" "$kver"

    feed_log "5/7 stage gh-pages and check it on localhost"
    origins="$(feed_custom_origins "$ROOT/x3000/custom-feeds.txt")"
    feed_stage_release "$WORK/pages" "$tag" "$PUBLIC_BIN/packages" "$CUSTOM_SRC" "$origins" "$ROOT"
    feed_serve "$WORK/pages"
    feed_canary "$image" "$FEED_SERVE_URL" "$kver"
    if (( dry )); then
        feed_log "dry run OK: nothing was published and no release record was written"
        return 0
    fi

    feed_log "6/7 publish"
    commit="$(feed_publish "$WORK/pages" "$base" "feed: $tag")"

    feed_log "7/7 verify the live feed"
    feed_wait_pages_build "$commit"
    feed_wait_served "$FEED_BASE_URL" "$WORK/pages" "kmods/$tag/packages.adb" custom/packages.adb
    feed_canary "$image" "$FEED_BASE_URL" "$kver"
    feed_write_sums "$PUBLIC_BIN"
    feed_write_record "$PUBLIC_BIN" "$tag" "$head"
    feed_log "the feed for $tag is live. Test the image, then: x3000/release.sh upload $tag"
}

cmd_upload() {
    local tag title="" notes="" commit kver files exists=0
    local -a assets
    [[ $# -ge 1 ]] || usage
    tag="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) [[ $# -ge 2 ]] || usage; title="$2"; shift 2 ;;
            --notes-file) [[ $# -ge 2 ]] || usage; notes="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    feed_check_tag "$tag"

    feed_log "checking the artifacts against what 'feed $tag' verified"
    commit="$(feed_check_record "$PUBLIC_BIN" "$tag")"
    if feed_release_exists "$tag"; then
        exists=1
    else
        [[ -n "$title" && -n "$notes" ]] || feed_die "$tag is a new release: pass --title and --notes-file"
        [[ -f "$notes" ]] || feed_die "no such notes file: $notes"
    fi

    kver="$(feed_manifest_kernel "$(feed_manifest_path "$PUBLIC_BIN")")"
    # The private build normally happens between feed and upload, so this
    # is the check that can actually see it.
    feed_check_private_kernel "$PRIVATE_BIN" "$tag" "$kver"

    feed_log "re-running the canary against the live feed"
    feed_canary "$(feed_sysupgrade_path "$PUBLIC_BIN")" "$FEED_BASE_URL" "$kver"

    files="$(feed_release_files "$PUBLIC_BIN")"
    mapfile -t assets <<< "$files"
    if (( exists )); then
        feed_log "replacing the assets of release $tag"
        gh release upload "$tag" "${assets[@]}" --clobber -R "$RELEASE_GH_REPO"
    else
        feed_log "creating release $tag at $commit"
        gh release create "$tag" "${assets[@]}" --target "$commit" \
            --title "$title" --notes-file "$notes" -R "$RELEASE_GH_REPO"
    fi
    feed_log "release $tag uploaded"
}

case "${1:-}" in
    feed) shift; cmd_feed "$@" ;;
    upload) shift; cmd_upload "$@" ;;
    *) usage ;;
esac
