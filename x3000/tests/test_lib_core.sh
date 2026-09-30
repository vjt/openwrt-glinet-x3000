# Core helpers of x3000/lib/feed.sh.

test_check_tag_accepts_release_names() {
    assert_ok "feed_check_tag jeeves-r9; feed_check_tag v1.2_rc3"
}

test_check_tag_rejects_url_unsafe_names() {
    assert_fails "feed_check_tag 'r9/../x'" "bad tag"
    assert_fails "feed_check_tag ''" "bad tag"
    assert_fails "feed_check_tag '-r9'" "bad tag"
}

test_repo_list_points_at_tag_and_custom() {
    local got
    got="$(feed_repo_list jeeves-r9 https://feed.example)"
    assert_eq "$got" "https://feed.example/kmods/jeeves-r9/packages.adb
https://feed.example/custom/packages.adb"
}

test_repo_list_defaults_to_the_public_feed() {
    local got
    got="$(feed_repo_list t1)"
    assert_eq "$got" "https://vjt.github.io/x3000-feed/kmods/t1/packages.adb
https://vjt.github.io/x3000-feed/custom/packages.adb"
}

test_list_entries_skips_comments_and_blanks() {
    cat > "$TEST_TMP/feeds.txt" <<'EOT'
# header comment

a   https://example.invalid/a.git   master   openwrt/a   # trailing
	b https://example.invalid/b.git v1 openwrt/b
EOT
    local got
    got="$(feed_list_entries "$TEST_TMP/feeds.txt")"
    assert_eq "$got" "a https://example.invalid/a.git master openwrt/a
b https://example.invalid/b.git v1 openwrt/b"
}

test_list_entries_rejects_malformed_line() {
    printf 'a https://example.invalid/a.git master\n' > "$TEST_TMP/feeds.txt"
    assert_fails "feed_list_entries '$TEST_TMP/feeds.txt'" "malformed line"
}

test_custom_origins_follow_the_prepare_layout() {
    cat > "$TEST_TMP/feeds.txt" <<'EOT'
qfirehose     https://github.com/vjt/qfirehose.git master openwrt/qfirehose
android-tools https://github.com/vjt/openwrt-android-tools.git master openwrt/android-tools
brotli        https://github.com/vjt/openwrt-android-tools.git master openwrt/brotli
EOT
    local got
    got="$(feed_custom_origins "$TEST_TMP/feeds.txt")"
    assert_eq "$got" ".build-deps/openwrt-android-tools/openwrt/android-tools
.build-deps/openwrt-android-tools/openwrt/brotli
.build-deps/qfirehose/openwrt/qfirehose"
}

test_custom_origins_of_the_real_list_match_built_packages() {
    # Origins seen with `apk adbdump` on r8's custom packages.
    local got
    got="$(feed_custom_origins "$X3000_REAL_ROOT/x3000/custom-feeds.txt")"
    assert_contains "$got" ".build-deps/openwrt-android-tools/openwrt/brotli"
    assert_contains "$got" ".build-deps/quectel-5g-tools/openwrt/quectel-5g-tools"
    assert_eq "$(wc -l <<< "$got")" "5"
}

test_hostbin_dies_on_missing_tool() {
    assert_fails "FEED_HOST_BIN='$TEST_TMP/nope' feed_hostbin apk" "missing host tool"
}

test_apk_runs_the_host_apk() {
    local got
    got="$(feed_apk --version)"
    assert_contains "$got" "apk-tools 3."
}
