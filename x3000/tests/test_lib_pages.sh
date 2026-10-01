# gh-pages remote, continuity guard, publish, waits, tag guard.

setup_pages() {
    fx_root "$TEST_TMP/root"
    fx_www
    fx_pages_remote
    fx_gh_stub
    export FEED_GH_REPO=test/feed RELEASE_GH_REPO=test/fw FEED_POLL_INTERVAL=0.2
}

# Publishes a custom/ signed with the key in $1 (a dir with a key pair)
# straight to the bare remote, as an earlier release would have.
publish_custom_signed_by() {
    local w="$TEST_TMP/w-$RANDOM"
    git clone -q --branch gh-pages "$FEED_GIT_URL" "$w" 2>/dev/null
    fx_apk "$w/custom" quectel-5g-tools 1.10.2-r1 libc
    feed_reindex "$w/custom" "$1"
    git -C "$w" add -A
    git -C "$w" commit -q -m custom
    git -C "$w" push -q origin gh-pages 2>/dev/null
}

test_clone_pages_prints_the_cloned_commit() {
    setup_pages
    local got
    got="$(feed_clone_pages "$TEST_TMP/c")"
    assert_eq "$got" "$(fx_pages_sha)"
    assert_file "$TEST_TMP/c/spike/x3000-feed-probe-1.0-r1.apk"
}

test_clone_pages_without_branch_prints_nothing() {
    setup_pages
    git init -q --bare "$TEST_TMP/empty.git"
    local got
    got="$(FEED_GIT_URL="file://$TEST_TMP/empty.git" feed_clone_pages "$TEST_TMP/c")"
    assert_eq "$got" ""
    assert_eq "$(git -C "$TEST_TMP/c" remote get-url origin)" "file://$TEST_TMP/empty.git"
}

test_continuity_skips_when_nothing_is_published() {
    setup_pages
    feed_clone_pages "$TEST_TMP/c" >/dev/null
    assert_ok "feed_continuity_check '$TEST_TMP/c' '$TEST_TMP/root'"
    assert_contains "$RUN_OUT" "skipping"
}

test_continuity_passes_with_the_same_key() {
    setup_pages
    publish_custom_signed_by "$TEST_TMP/root"
    feed_clone_pages "$TEST_TMP/c" >/dev/null
    assert_ok "feed_continuity_check '$TEST_TMP/c' '$TEST_TMP/root'"
    assert_contains "$RUN_OUT" "verifies with"
}

test_continuity_fails_when_the_key_changed() {
    setup_pages
    fx_key "$TEST_TMP/throwaway"
    publish_custom_signed_by "$TEST_TMP/throwaway"
    feed_clone_pages "$TEST_TMP/c" >/dev/null
    assert_fails "feed_continuity_check '$TEST_TMP/c' '$TEST_TMP/root'" "is not signed by"
}

test_continuity_fails_when_published_index_is_unreachable() {
    setup_pages
    publish_custom_signed_by "$TEST_TMP/root"
    feed_clone_pages "$TEST_TMP/c" >/dev/null
    rm -rf "$TEST_TMP/www/feed/custom"
    assert_fails "feed_continuity_check '$TEST_TMP/c' '$TEST_TMP/root'" "cannot be fetched"
}

test_publish_force_pushes_a_single_orphan_commit() {
    setup_pages
    local base commit
    base="$(feed_clone_pages "$TEST_TMP/c")"
    rm -rf "$TEST_TMP/c/spike"
    echo t1 > "$TEST_TMP/c/TAGS"
    commit="$(feed_publish "$TEST_TMP/c" "$base" "feed: t1")"
    assert_eq "$commit" "$(fx_pages_sha)"
    assert_eq "$(git --git-dir="$FX_PAGES_BARE" rev-list --count gh-pages)" 1
    assert_eq "$(cat "$TEST_TMP/www/feed/TAGS")" t1
    assert_no_file "$TEST_TMP/www/feed/spike"
}

test_publish_refuses_when_gh_pages_moved_meanwhile() {
    setup_pages
    local base concurrent
    base="$(feed_clone_pages "$TEST_TMP/c")"
    fx_root "$TEST_TMP/other-root"
    publish_custom_signed_by "$TEST_TMP/other-root"
    concurrent="$(fx_pages_sha)"
    echo t1 > "$TEST_TMP/c/TAGS"
    assert_fails "cd '$TEST_TMP/c' && feed_publish '$TEST_TMP/c' '$base' 'feed: t1'" "push to"
    assert_eq "$(fx_pages_sha)" "$concurrent"
}

test_publish_creates_a_missing_branch() {
    setup_pages
    git init -q --bare "$TEST_TMP/empty.git"
    export FEED_GIT_URL="file://$TEST_TMP/empty.git"
    local base commit
    base="$(feed_clone_pages "$TEST_TMP/c")"
    echo t1 > "$TEST_TMP/c/TAGS"
    commit="$(feed_publish "$TEST_TMP/c" "$base" "feed: t1")"
    assert_eq "$commit" "$(git --git-dir="$TEST_TMP/empty.git" rev-parse gh-pages)"
}

test_wait_pages_build_returns_when_built() {
    setup_pages
    assert_ok "feed_wait_pages_build '$(fx_pages_sha)'"
}

test_wait_pages_build_dies_when_errored() {
    setup_pages
    assert_fails "FX_PAGES_STATUS=errored feed_wait_pages_build '$(fx_pages_sha)'" "errored"
}

test_wait_pages_build_times_out() {
    setup_pages
    assert_fails "FEED_TIMEOUT=1 feed_wait_pages_build 0000000000000000000000000000000000000000" "did not build"
}

test_wait_served_matches_the_staged_bytes() {
    setup_pages
    mkdir -p "$TEST_TMP/stage"
    cp -a "$TEST_TMP/www/feed/." "$TEST_TMP/stage/"
    assert_ok "feed_wait_served '$FEED_BASE_URL' '$TEST_TMP/stage' spike/x3000-feed-probe-1.0-r1.apk"
    echo changed > "$TEST_TMP/stage/spike/x3000-feed-probe-1.0-r1.apk"
    assert_fails "FEED_TIMEOUT=1 feed_wait_served '$FEED_BASE_URL' '$TEST_TMP/stage' spike/x3000-feed-probe-1.0-r1.apk" \
        "does not serve the published bytes"
}

test_release_exists() {
    setup_pages
    mkdir -p "$TEST_TMP/releases/t0"
    assert_ok "feed_release_exists t0"
    assert_fails "feed_release_exists t9" ""
}

test_check_new_tag_refuses_released_tag_outside_tags() {
    setup_pages
    mkdir -p "$TEST_TMP/releases/jeeves-r8" "$TEST_TMP/stage"
    assert_fails "feed_check_new_tag '$TEST_TMP/stage' jeeves-r8" "already released but not in the feed's TAGS"
}

test_check_new_tag_accepts_a_listed_tag() {
    setup_pages
    mkdir -p "$TEST_TMP/releases/t1" "$TEST_TMP/stage"
    echo t1 > "$TEST_TMP/stage/TAGS"
    assert_ok "feed_check_new_tag '$TEST_TMP/stage' t1"
}

test_check_new_tag_accepts_an_unreleased_tag() {
    setup_pages
    mkdir -p "$TEST_TMP/stage"
    assert_ok "feed_check_new_tag '$TEST_TMP/stage' t9"
}
