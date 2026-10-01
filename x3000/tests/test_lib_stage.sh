# Step 5: staging on top of gh-pages, immutability, retention.

setup_stage() {
    R="$TEST_TMP/root"
    S="$TEST_TMP/stage"
    fx_root "$R"
    fx_build_outputs "$R" t1
    fx_feeds_txt "$TEST_TMP/feeds.txt"
    ORIGINS="$(feed_custom_origins "$TEST_TMP/feeds.txt")"
    CUSTOM="$R/bin/packages/$FEED_ARCH/custom"
    mkdir -p "$S"
}

test_stage_file_copies_new_names() {
    mkdir -p "$TEST_TMP/src" "$TEST_TMP/dst"
    echo new > "$TEST_TMP/src/a-1.0-r1.apk"
    feed_stage_file "$TEST_TMP/src/a-1.0-r1.apk" "$TEST_TMP/dst"
    assert_eq "$(cat "$TEST_TMP/dst/a-1.0-r1.apk")" new
}

test_stage_file_never_rewrites_a_published_name() {
    mkdir -p "$TEST_TMP/src" "$TEST_TMP/dst"
    echo rebuilt > "$TEST_TMP/src/a-1.0-r1.apk"
    echo published > "$TEST_TMP/dst/a-1.0-r1.apk"
    local out
    out="$(feed_stage_file "$TEST_TMP/src/a-1.0-r1.apk" "$TEST_TMP/dst" 2>&1)"
    assert_eq "$(cat "$TEST_TMP/dst/a-1.0-r1.apk")" published
    assert_contains "$out" "kept published a-1.0-r1.apk"
}

test_select_custom_keeps_public_origins_only() {
    setup_stage
    local got
    got="$(feed_select_custom "$CUSTOM" "$ORIGINS" 2>"$TEST_TMP/log")"
    assert_contains "$got" "quectel-5g-tools-1.10.2-r1.apk"
    assert_contains "$got" "libbrotlicommon-1.1.0-r1.apk"
    assert_not_contains "$got" "secret-pkg"
    assert_contains "$(cat "$TEST_TMP/log")" "excluded secret-pkg-1.0-r1.apk"
}

test_select_custom_dies_when_a_listed_origin_built_nothing() {
    setup_stage
    local origins="$ORIGINS"$'\n'".build-deps/qfirehose/openwrt/qfirehose"
    assert_fails "feed_select_custom '$CUSTOM' '$origins'" "no package built from .build-deps/qfirehose/openwrt/qfirehose"
}

test_update_tags_newest_first_keeps_three() {
    setup_stage
    printf 't3\nt2\nt1\n' > "$S/TAGS"
    mkdir -p "$S/kmods/t1" "$S/kmods/t2" "$S/kmods/t3" "$S/kmods/t4" "$S/kmods/stray"
    feed_update_tags "$S" t4
    assert_eq "$(cat "$S/TAGS")" "t4
t3
t2"
    assert_no_file "$S/kmods/t1"
    assert_no_file "$S/kmods/stray"
    [[ -d "$S/kmods/t4" && -d "$S/kmods/t2" ]] || fail "retained kmods dirs gone"
}

test_update_tags_refresh_keeps_order() {
    setup_stage
    printf 't3\nt2\nt1\n' > "$S/TAGS"
    feed_update_tags "$S" t2
    assert_eq "$(cat "$S/TAGS")" "t3
t2
t1"
}

test_version_sort_is_apk_order() {
    local got
    got="$(printf '1.9.0-r1\n1.10.10-r1\n1.10.2-r1\n' | feed_version_sort_desc)"
    assert_eq "$got" "1.10.10-r1
1.10.2-r1
1.9.0-r1"
}

test_prune_custom_keeps_two_newest_by_apk_version() {
    setup_stage
    fx_apk "$S/custom" quectel-5g-tools 1.9.0-r1 libc
    fx_apk "$S/custom" quectel-5g-tools 1.10.2-r1 libc
    fx_apk "$S/custom" quectel-5g-tools 1.10.10-r1 libc
    fx_apk "$S/custom" libbrotlicommon 1.1.0-r1 libc
    feed_prune_custom "$S"
    assert_no_file "$S/custom/quectel-5g-tools-1.9.0-r1.apk"
    assert_file "$S/custom/quectel-5g-tools-1.10.2-r1.apk"
    assert_file "$S/custom/quectel-5g-tools-1.10.10-r1.apk"
    assert_file "$S/custom/libbrotlicommon-1.1.0-r1.apk"
}

test_prune_unknown_drops_spike() {
    setup_stage
    mkdir -p "$S/spike" "$S/spike-bad" "$S/kmods" "$S/custom" "$S/.git"
    touch "$S/.nojekyll" "$S/TAGS" "$S/README.md" "$S/.stray"
    feed_prune_unknown "$S"
    assert_no_file "$S/spike"
    assert_no_file "$S/spike-bad"
    assert_no_file "$S/README.md"
    assert_no_file "$S/.stray"
    assert_file "$S/.nojekyll"
    assert_file "$S/TAGS"
    [[ -d "$S/kmods" && -d "$S/custom" && -d "$S/.git" ]] || fail "layout dirs gone"
}

test_stage_release_builds_the_layout() {
    setup_stage
    mkdir -p "$S/spike"
    touch "$S/spike/x3000-feed-probe-1.0-r1.apk"
    feed_stage_release "$S" t1 "$R/bin-x3000-public/packages" "$CUSTOM" "$ORIGINS" "$R"
    local listing
    listing="$(cd "$S" && find . -type f | sort)"
    assert_eq "$listing" "./.nojekyll
./TAGS
./custom/libbrotlicommon-1.1.0-r1.apk
./custom/packages.adb
./custom/quectel-5g-tools-1.10.2-r1.apk
./kmods/t1/kernel-${FX_KVER_DEFAULT}.apk
./kmods/t1/kmod-tun-6.12.103-r1.apk
./kmods/t1/kmod-wireguard-6.12.103-r1.apk
./kmods/t1/packages.adb"
    assert_eq "$(cat "$S/TAGS")" t1
    assert_ok "feed_verify_index '$S/kmods/t1/packages.adb' '$R/public-key.pem'"
    assert_ok "feed_verify_index '$S/custom/packages.adb' '$R/public-key.pem'"
}

test_stage_custom_only_leaves_kmods_alone() {
    setup_stage
    feed_stage_release "$S" t1 "$R/bin-x3000-public/packages" "$CUSTOM" "$ORIGINS" "$R"
    local before
    before="$(sha256sum < "$S/kmods/t1/packages.adb")"
    FX_CUSTOM_VER=1.10.3-r1 fx_build_outputs "$R" t1
    feed_stage_custom_only "$S" "$CUSTOM" "$ORIGINS" "$R"
    assert_eq "$(sha256sum < "$S/kmods/t1/packages.adb")" "$before"
    assert_file "$S/custom/quectel-5g-tools-1.10.2-r1.apk"
    assert_file "$S/custom/quectel-5g-tools-1.10.3-r1.apk"
    assert_ok "feed_verify_index '$S/custom/packages.adb' '$R/public-key.pem'"
}

test_version_sort_fails_closed_on_uncomparable_versions() {
    # apk prints nothing and exits 1 for a version it cannot parse.
    assert_fails "printf '1.0-r1\n<bad>\n' | feed_version_sort_desc" "cannot compare versions '1.0-r1' and '<bad>'"
}

test_version_sort_keeps_equal_versions() {
    local got
    got="$(printf '1.0-r1\n1.0-r1\n' | feed_version_sort_desc)"
    assert_eq "$got" "1.0-r1
1.0-r1"
}
