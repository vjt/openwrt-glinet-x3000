# release.sh end to end: fixture tree, fake build, local Pages, fake gh.

rel_setup() {
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

run_release() {
    RC=0
    OUT="$("$T/x3000/release.sh" "$@" 2>&1)" || RC=$?
}

# Runs release.sh with the given args, expects it to fail with want,
# and gh-pages to be untouched.
assert_stops_before_publish() {
    local want="$1" before
    shift
    before="$(fx_pages_sha)"
    run_release "$@"
    [[ "$RC" -ne 0 ]] || fail "expected release.sh $* to fail; got:"$'\n'"$OUT"
    assert_contains "$OUT" "$want"
    assert_eq "$(fx_pages_sha)" "$before" "gh-pages must be untouched"
}

test_feed_publishes_live_feed_and_records_hashes() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$OUT" "canary: kmod-wireguard wireguard-tools resolves"
    assert_contains "$OUT" "Pages built"
    assert_file "$SITE/kmods/t1/packages.adb"
    assert_file "$SITE/kmods/t1/kmod-wireguard-6.12.103-r1.apk"
    assert_file "$SITE/custom/quectel-5g-tools-1.10.2-r1.apk"
    assert_file "$SITE/.nojekyll"
    assert_no_file "$SITE/custom/secret-pkg-1.0-r1.apk"
    assert_no_file "$SITE/spike"
    assert_eq "$(cat "$SITE/TAGS")" t1
    assert_contains "$(cat "$T/bin-x3000-public/.release-t1")" "commit $(git -C "$T" rev-parse HEAD)"
    assert_file "$T/bin-x3000-public/SHA256SUMS"
}

test_feed_dry_run_publishes_nothing() {
    rel_setup
    local before
    before="$(fx_pages_sha)"
    run_release feed --dry-run t1
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$OUT" "canary: kmod-wireguard wireguard-tools resolves"
    assert_contains "$OUT" "dry run OK"
    assert_eq "$(fx_pages_sha)" "$before"
    assert_no_file "$T/bin-x3000-public/.release-t1"
}

test_feed_dry_run_tolerates_an_unpushed_tree() {
    # The tree guard only warns in a dry run. (The revision check still
    # applies; the fixture's getver stub is unaffected by the commit.)
    rel_setup
    git -C "$T" commit -q --allow-empty -m unpushed
    run_release feed --dry-run t1
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$OUT" "WARNING: HEAD is not pushed"
    assert_contains "$OUT" "dry run OK"
}

test_feed_refuses_unpushed_tree() {
    rel_setup
    git -C "$T" commit -q --allow-empty -m unpushed
    assert_stops_before_publish "not pushed" feed t1
    assert_no_file "$TEST_TMP/build.log"
}

test_feed_refuses_dirty_tree() {
    rel_setup
    echo "# edit" >> "$T/x3000/custom-feeds.txt"
    assert_stops_before_publish "uncommitted changes" feed t1
}

test_feed_refuses_missing_key() {
    rel_setup
    rm "$T/private-key.pem"
    assert_stops_before_publish "private-key.pem is missing" feed t1
}

test_feed_refuses_mismatched_key() {
    rel_setup
    fx_key "$TEST_TMP/other"
    cp "$TEST_TMP/other/public-key.pem" "$T/public-key.pem"
    assert_stops_before_publish "does not derive" feed t1
}

test_feed_refuses_wrong_feed_tag() {
    rel_setup
    export FX_FEED_TAG=t0
    assert_stops_before_publish "FEED_TAG says 't0'" feed t1
}

test_feed_refuses_image_without_feed_list() {
    rel_setup
    export FX_NO_LIST=1
    assert_stops_before_publish "x3000feed.list" feed t1
}

test_feed_refuses_private_variant() {
    rel_setup
    export FX_TELEGRAF=1
    assert_stops_before_publish "private variant" feed t1
}

test_feed_refuses_foreign_kmod() {
    rel_setup
    export FX_FOREIGN_KMOD=1
    assert_stops_before_publish "kmods not built for kernel=" feed t1
}

test_feed_refuses_private_build_with_another_kernel() {
    rel_setup
    mkdir -p "$T/bin-x3000-private"
    echo t1 > "$T/bin-x3000-private/FEED_TAG"
    echo "kernel - 6.12.104~aa-r1" > "$(feed_manifest_path "$T/bin-x3000-private")"
    assert_stops_before_publish "bin-x3000-private (also t1) has kernel 6.12.104~aa-r1" feed t1
}

test_feed_refuses_refresh_with_changed_kernel() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    export FX_KVER='6.12.104~0123456789abcdef0123456789abcdef-r1'
    assert_stops_before_publish "kernel changed → cut a new tag" feed t1
}

test_feed_refresh_with_same_kernel_republishes() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    assert_eq "$(cat "$SITE/TAGS")" t1
}

test_feed_refuses_when_the_published_key_changed() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    fx_key "$TEST_TMP/throwaway"
    feed_reindex "$SITE/custom" "$TEST_TMP/throwaway"
    assert_stops_before_publish "is not signed by" feed t2
}

test_feed_refuses_released_tag_outside_feed() {
    rel_setup
    mkdir -p "$TEST_TMP/releases/jeeves-r8"
    assert_stops_before_publish "already released but not in the feed's TAGS" feed jeeves-r8
}

test_feed_stops_on_unsatisfiable_custom_dependency() {
    rel_setup
    export FX_CUSTOM_DEPS="libc libmissing"
    assert_stops_before_publish "canary: apk add --simulate" feed t1
}

test_feed_keeps_three_tags() {
    rel_setup
    local t
    for t in t1 t2 t3 t4; do
        run_release feed "$t"
        assert_eq "$RC" 0 "$OUT"
    done
    assert_eq "$(cat "$SITE/TAGS")" "t4
t3
t2"
    assert_no_file "$SITE/kmods/t1"
}

test_upload_without_feed_refuses() {
    rel_setup
    fx_build_outputs "$T" t1
    run_release upload t1 --title T --notes-file "$TEST_TMP/notes.md"
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "run 'release.sh feed t1' first"
    assert_not_contains "$(cat "$TEST_TMP/gh.log" 2>/dev/null)" "release create"
}

test_upload_refuses_modified_artifacts() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    echo tampered >> "$T/bin-x3000-public/$FEED_IMAGE_PREFIX.manifest"
    run_release upload t1 --title T --notes-file "$TEST_TMP/notes.md"
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "changed since"
    assert_no_file "$TEST_TMP/releases/t1"
}

test_upload_creates_new_release_from_public_bin() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    run_release upload t1 --title "Jeeves t1" --notes-file "$TEST_TMP/notes.md"
    assert_eq "$RC" 0 "$OUT"
    local log
    log="$(cat "$TEST_TMP/gh.log")"
    assert_contains "$log" "release create t1"
    assert_contains "$log" "--target $(git -C "$T" rev-parse HEAD)"
    assert_eq "$(ls "$TEST_TMP/releases/t1" | sort | tr '\n' ' ')" \
        "SHA256SUMS $FEED_IMAGE_PREFIX-bl31-uboot.fip $FEED_IMAGE_PREFIX-preloader.bin $FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin $FEED_IMAGE_PREFIX.manifest "
}

test_upload_new_release_needs_title_and_notes() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    run_release upload t1
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "pass --title and --notes-file"
}

test_upload_refreshes_an_existing_release() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    mkdir -p "$TEST_TMP/releases/t1"
    run_release upload t1
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$(cat "$TEST_TMP/gh.log")" "release upload t1"
    assert_contains "$(cat "$TEST_TMP/gh.log")" "--clobber"
}

test_upload_reruns_the_canary_against_the_live_feed() {
    rel_setup
    run_release feed t1
    assert_eq "$RC" 0 "$OUT"
    rm "$SITE/kmods/t1/packages.adb"
    run_release upload t1 --title T --notes-file "$TEST_TMP/notes.md"
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "canary"
    assert_no_file "$TEST_TMP/releases/t1"
}
