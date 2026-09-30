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
