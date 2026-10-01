# prepare.sh release mode, run end to end in a fixture tree.

run_prepare() {
    RC=0
    OUT="$("$TEST_TMP/tree/x3000/prepare.sh" "$@" 2>&1)" || RC=$?
}

test_prepare_release_writes_the_feed_list() {
    fx_prepare_tree "$TEST_TMP/tree"
    fx_key "$TEST_TMP/tree"
    run_prepare public --release jeeves-r9
    assert_eq "$RC" 0 "$OUT"
    assert_eq "$(cat "$TEST_TMP/tree/files/etc/apk/repositories.d/x3000feed.list")" "$(feed_repo_list jeeves-r9)"
    assert_eq "$(cat "$TEST_TMP/tree/.x3000-variant")" public
}

test_prepare_default_mode_needs_no_key_and_writes_no_list() {
    fx_prepare_tree "$TEST_TMP/tree"
    run_prepare public
    assert_eq "$RC" 0 "$OUT"
    assert_file "$TEST_TMP/tree/.config"
    assert_no_file "$TEST_TMP/tree/files/etc/apk/repositories.d/x3000feed.list"
}

test_prepare_release_refuses_without_key_before_touching_the_tree() {
    fx_prepare_tree "$TEST_TMP/tree"
    mkdir -p "$TEST_TMP/tree/files"
    touch "$TEST_TMP/tree/files/sentinel"
    run_prepare public --release jeeves-r9
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "private-key.pem is missing"
    assert_file "$TEST_TMP/tree/files/sentinel"
    assert_no_file "$TEST_TMP/tree/.config"
}

test_prepare_release_refuses_mismatched_key() {
    fx_prepare_tree "$TEST_TMP/tree"
    fx_key "$TEST_TMP/tree"
    fx_key "$TEST_TMP/other"
    cp "$TEST_TMP/other/public-key.pem" "$TEST_TMP/tree/public-key.pem"
    run_prepare public --release jeeves-r9
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "does not derive"
}

test_prepare_rejects_bad_tag() {
    fx_prepare_tree "$TEST_TMP/tree"
    fx_key "$TEST_TMP/tree"
    run_prepare public --release 'r9/x'
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "bad tag"
}

test_prepare_rejects_unknown_argument() {
    fx_prepare_tree "$TEST_TMP/tree"
    run_prepare public --relase jeeves-r9
    assert_eq "$RC" 2 "$OUT"
    assert_contains "$OUT" "unknown argument: --relase"
}

test_prepare_release_needs_a_tag() {
    fx_prepare_tree "$TEST_TMP/tree"
    run_prepare public --release
    assert_eq "$RC" 2 "$OUT"
    assert_contains "$OUT" "usage:"
}

test_prepare_public_release_refuses_gitignored_overlays() {
    # A public release build must not read gitignored per-builder files:
    # the release record names a commit that does not contain them.
    local f
    for f in config.public.local custom-feeds.public.local; do
        fx_prepare_tree "$TEST_TMP/tree"
        fx_key "$TEST_TMP/tree"
        mkdir -p "$TEST_TMP/tree/files"
        touch "$TEST_TMP/tree/files/sentinel"
        echo "# local" > "$TEST_TMP/tree/x3000/$f"
        run_prepare public --release jeeves-r9
        assert_eq "$RC" 1 "$OUT"
        assert_contains "$OUT" "x3000/$f"
        assert_file "$TEST_TMP/tree/files/sentinel"
        assert_no_file "$TEST_TMP/tree/.config"
        rm -rf "$TEST_TMP/tree"
    done
}

test_prepare_public_default_mode_reads_the_overlays() {
    fx_prepare_tree "$TEST_TMP/tree"
    echo "CONFIG_PACKAGE_foo=y" > "$TEST_TMP/tree/x3000/config.public.local"
    run_prepare public
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$(cat "$TEST_TMP/tree/.config")" "CONFIG_PACKAGE_foo=y"
}

test_prepare_private_release_keeps_its_local_overlays() {
    fx_prepare_tree "$TEST_TMP/tree"
    fx_key "$TEST_TMP/tree"
    echo "CONFIG_PACKAGE_foo=y" > "$TEST_TMP/tree/x3000/config.private.local"
    run_prepare private --release jeeves-r9
    assert_eq "$RC" 0 "$OUT"
    assert_contains "$(cat "$TEST_TMP/tree/.config")" "CONFIG_PACKAGE_foo=y"
}
