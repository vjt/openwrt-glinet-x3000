# publish-feed.sh custom end to end.

pub_setup() {
    T="$TEST_TMP/tree"
    SITE="$TEST_TMP/www/feed"
    fx_tree "$T"
    fx_www
    fx_upstream
    fx_pages_remote
    fx_gh_stub
    export FX_ROOT="$T" X3000_BUILD_CMD="$X3000_REAL_ROOT/x3000/tests/lib/fake-build.sh"
    export FEED_GH_REPO=test/feed RELEASE_GH_REPO=test/fw FEED_TIMEOUT=20 FEED_POLL_INTERVAL=0.2
    printf 'Release notes.\n' > "$TEST_TMP/notes.md"
}

# A released t1 with its feed, as after release.sh feed + upload.
released_t1() {
    local out
    out="$("$T/x3000/release.sh" feed t1 2>&1)" || fail "feed t1: $out"
    out="$("$T/x3000/release.sh" upload t1 --title T --notes-file "$TEST_TMP/notes.md" 2>&1)" || fail "upload t1: $out"
}

run_publish() {
    RC=0
    OUT="$("$T/x3000/publish-feed.sh" "$@" 2>&1)" || RC=$?
}

test_publish_custom_ships_a_new_version() {
    pub_setup
    released_t1
    local kmods_before
    kmods_before="$(sha256sum < "$SITE/kmods/t1/packages.adb")"
    export FX_CUSTOM_VER=1.10.3-r1
    run_publish custom
    assert_eq "$RC" 0 "$OUT"
    assert_file "$SITE/custom/quectel-5g-tools-1.10.2-r1.apk"
    assert_file "$SITE/custom/quectel-5g-tools-1.10.3-r1.apk"
    assert_eq "$(sha256sum < "$SITE/kmods/t1/packages.adb")" "$kmods_before"
    assert_eq "$(cat "$SITE/TAGS")" t1
    assert_contains "$(awk 'END { print }' "$TEST_TMP/build.log")" "build public --release t1"
    assert_contains "$OUT" "canary: libbrotlicommon quectel-5g-tools resolves"
}

test_publish_custom_keeps_two_versions() {
    pub_setup
    released_t1
    export FX_CUSTOM_VER=1.10.3-r1
    run_publish custom
    assert_eq "$RC" 0 "$OUT"
    export FX_CUSTOM_VER=1.10.10-r1
    run_publish custom
    assert_eq "$RC" 0 "$OUT"
    assert_no_file "$SITE/custom/quectel-5g-tools-1.10.2-r1.apk"
    assert_file "$SITE/custom/quectel-5g-tools-1.10.3-r1.apk"
    assert_file "$SITE/custom/quectel-5g-tools-1.10.10-r1.apk"
}

test_publish_custom_dry_run_publishes_nothing() {
    pub_setup
    released_t1
    local before
    before="$(fx_pages_sha)"
    export FX_CUSTOM_VER=1.10.3-r1
    run_publish custom --dry-run
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$OUT" "dry run OK"
    assert_eq "$(fx_pages_sha)" "$before"
}

test_publish_custom_stops_on_unsatisfiable_dependency() {
    pub_setup
    released_t1
    local before
    before="$(fx_pages_sha)"
    export FX_CUSTOM_VER=1.10.3-r1 FX_CUSTOM_DEPS="libc libmissing"
    run_publish custom
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "canary: apk add --simulate"
    assert_eq "$(fx_pages_sha)" "$before"
}

test_publish_custom_needs_a_published_tag() {
    pub_setup
    run_publish custom
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "no tag published yet"
}

test_publish_custom_needs_the_github_release() {
    pub_setup
    local out
    out="$("$T/x3000/release.sh" feed t1 2>&1)" || fail "feed t1: $out"
    run_publish custom
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "cannot download release t1"
}

test_publish_custom_refuses_tampered_release_assets() {
    pub_setup
    released_t1
    echo tampered >> "$TEST_TMP/releases/t1/$FEED_IMAGE_PREFIX.manifest"
    run_publish custom
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "do not match its SHA256SUMS"
}

test_publish_custom_refuses_when_the_published_key_changed() {
    pub_setup
    released_t1
    fx_key "$TEST_TMP/throwaway"
    feed_reindex "$SITE/custom" "$TEST_TMP/throwaway"
    local before
    before="$(fx_pages_sha)"
    run_publish custom
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "is not signed by"
    assert_eq "$(fx_pages_sha)" "$before"
}

test_publish_rejects_unknown_subcommand() {
    pub_setup
    run_publish kmods
    assert_eq "$RC" 2 "$OUT"
    assert_contains "$OUT" "usage:"
}
