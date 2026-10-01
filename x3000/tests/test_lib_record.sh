# Tree guard and the feed → upload record.

test_tree_clean_and_pushed_ok() {
    fx_tree "$TEST_TMP/tree"
    assert_ok "feed_check_tree '$TEST_TMP/tree' 1"
}

test_tree_dirty_is_fatal_when_strict() {
    fx_tree "$TEST_TMP/tree"
    echo "# edit" >> "$TEST_TMP/tree/x3000/custom-feeds.txt"
    assert_fails "feed_check_tree '$TEST_TMP/tree' 1" "uncommitted changes"
}

test_tree_dirty_only_warns_in_dry_run() {
    fx_tree "$TEST_TMP/tree"
    echo "# edit" >> "$TEST_TMP/tree/x3000/custom-feeds.txt"
    assert_ok "feed_check_tree '$TEST_TMP/tree' 0"
    assert_contains "$RUN_OUT" "WARNING: tracked files have uncommitted changes or the tree has untracked files"
}

test_tree_untracked_file_is_fatal_when_strict() {
    # prepare.sh applies an untracked patch / overlay file, so the release
    # record's commit would not contain what is in the image.
    fx_tree "$TEST_TMP/tree"
    echo x > "$TEST_TMP/tree/x3000/patches-extra.patch"
    assert_fails "feed_check_tree '$TEST_TMP/tree' 1" "untracked"
}

test_tree_untracked_file_only_warns_in_dry_run() {
    fx_tree "$TEST_TMP/tree"
    mkdir -p "$TEST_TMP/tree/x3000/files-common/etc"
    echo x > "$TEST_TMP/tree/x3000/files-common/etc/new"
    assert_ok "feed_check_tree '$TEST_TMP/tree' 0"
    assert_contains "$RUN_OUT" "WARNING: "
    assert_contains "$RUN_OUT" "untracked"
}

test_tree_unpushed_is_fatal_when_strict() {
    fx_tree "$TEST_TMP/tree"
    git -C "$TEST_TMP/tree" commit -q --allow-empty -m unpushed
    assert_fails "feed_check_tree '$TEST_TMP/tree' 1" "not pushed"
}

test_sums_follow_the_release_order() {
    fx_root "$TEST_TMP/root"
    fx_build_outputs "$TEST_TMP/root" t1
    feed_write_sums "$TEST_TMP/root/bin-x3000-public"
    local got
    got="$(awk '{ print $2 }' "$TEST_TMP/root/bin-x3000-public/SHA256SUMS")"
    assert_eq "$got" "$FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin
$FEED_IMAGE_PREFIX-preloader.bin
$FEED_IMAGE_PREFIX-bl31-uboot.fip
$FEED_IMAGE_PREFIX.manifest"
}

test_record_roundtrip_prints_the_commit() {
    local b="$TEST_TMP/root/bin-x3000-public" got
    fx_root "$TEST_TMP/root"
    fx_build_outputs "$TEST_TMP/root" t1
    feed_write_sums "$b"
    feed_write_record "$b" t1 0123abcd
    got="$(feed_check_record "$b" t1)"
    assert_eq "$got" 0123abcd
}

test_record_missing() {
    fx_root "$TEST_TMP/root"
    fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_record '$TEST_TMP/root/bin-x3000-public' t1" "run 'release.sh feed t1' first"
}

test_record_detects_a_changed_artifact() {
    local b="$TEST_TMP/root/bin-x3000-public"
    fx_root "$TEST_TMP/root"
    fx_build_outputs "$TEST_TMP/root" t1
    feed_write_sums "$b"
    feed_write_record "$b" t1 0123abcd
    echo tampered >> "$(feed_manifest_path "$b")"
    assert_fails "feed_check_record '$b' t1" "changed since"
}
