# build.sh release mode, run end to end in a fixture tree (stub make).

run_build() {
    RC=0
    OUT="$("$TEST_TMP/tree/x3000/build.sh" "$@" 2>&1)" || RC=$?
}

stale_outputs() {
    local t="$TEST_TMP/tree"
    mkdir -p "$t/bin-x3000-public/packages" "$t/bin/packages/$FEED_ARCH/custom"
    touch "$t/bin-x3000-public/packages/base-files-1704~stale.apk" \
          "$t/bin/packages/$FEED_ARCH/custom/stale-1.0-r1.apk"
}

test_build_release_wipes_outputs_and_records_the_tag() {
    local t="$TEST_TMP/tree"
    fx_prepare_tree "$t"
    fx_key "$t"
    stale_outputs
    run_build public --release jeeves-r9 -- V=s
    assert_eq "$RC" 0 "$OUT"
    assert_no_file "$t/bin-x3000-public/packages/base-files-1704~stale.apk"
    assert_no_file "$t/bin/packages/$FEED_ARCH/custom/stale-1.0-r1.apk"
    assert_eq "$(cat "$t/bin-x3000-public/FEED_TAG")" jeeves-r9
    assert_contains "$(cat "$TEST_TMP/make.log")" "BIN_DIR=$t/bin-x3000-public V=s"
    assert_file "$t/files/etc/apk/repositories.d/x3000feed.list"
}

test_build_default_keeps_outputs_and_writes_no_tag() {
    local t="$TEST_TMP/tree"
    fx_prepare_tree "$t"
    stale_outputs
    run_build public
    assert_eq "$RC" 0 "$OUT"
    assert_file "$t/bin-x3000-public/packages/base-files-1704~stale.apk"
    assert_file "$t/bin/packages/$FEED_ARCH/custom/stale-1.0-r1.apk"
    assert_no_file "$t/bin-x3000-public/FEED_TAG"
    assert_no_file "$t/files/etc/apk/repositories.d/x3000feed.list"
}

test_build_release_without_key_wipes_nothing() {
    local t="$TEST_TMP/tree"
    fx_prepare_tree "$t"
    stale_outputs
    run_build public --release jeeves-r9
    assert_eq "$RC" 1 "$OUT"
    assert_contains "$OUT" "private-key.pem is missing"
    assert_file "$t/bin-x3000-public/packages/base-files-1704~stale.apk"
    assert_file "$t/bin/packages/$FEED_ARCH/custom/stale-1.0-r1.apk"
    assert_no_file "$TEST_TMP/make.log"
}

test_build_rejects_stray_argument() {
    fx_prepare_tree "$TEST_TMP/tree"
    run_build public V=s
    assert_eq "$RC" 2 "$OUT"
    assert_contains "$OUT" "unknown argument: V=s"
}

test_config_common_builds_every_kmod() {
    assert_contains "$(cat "$X3000_REAL_ROOT/x3000/config.common")" "CONFIG_ALL_KMODS=y"
}
