# The canary: what a device running the image would resolve.

setup_canary() {
    R="$TEST_TMP/root"
    FEEDDIR="$TEST_TMP/www/feed"
    fx_root "$R"
    fx_www
    fx_upstream
    fx_build_outputs "$R" t1
    fx_feeds_txt "$TEST_TMP/feeds.txt"
    mkdir -p "$FEEDDIR"
    feed_stage_release "$FEEDDIR" t1 "$R/bin-x3000-public/packages" \
        "$R/bin/packages/$FEED_ARCH/custom" "$(feed_custom_origins "$TEST_TMP/feeds.txt")" "$R"
    IMAGE="$(feed_sysupgrade_path "$R/bin-x3000-public")"
}

test_canary_resolves_kmods_and_custom() {
    setup_canary
    assert_ok "feed_canary '$IMAGE' '$FX_URL/feed' '$FX_KVER_DEFAULT'"
    assert_contains "$RUN_OUT" "canary: kmod-wireguard wireguard-tools resolves"
    assert_contains "$RUN_OUT" "canary: libbrotlicommon quectel-5g-tools resolves"
}

test_canary_fails_on_kmods_signed_by_another_key() {
    setup_canary
    fx_key "$TEST_TMP/throwaway"
    feed_reindex "$FEEDDIR/kmods/t1" "$TEST_TMP/throwaway"
    assert_fails "feed_canary '$IMAGE' '$FX_URL/feed' '$FX_KVER_DEFAULT'" "canary: the image's feeds include an UNTRUSTED index (apk add --initdb)"
    assert_contains "$RUN_OUT" "UNTRUSTED"
}

test_canary_fails_on_custom_signed_by_another_key() {
    setup_canary
    fx_key "$TEST_TMP/throwaway"
    feed_reindex "$FEEDDIR/custom" "$TEST_TMP/throwaway"
    assert_fails "feed_canary '$IMAGE' '$FX_URL/feed' '$FX_KVER_DEFAULT'" "UNTRUSTED"
}

test_canary_fails_on_another_kernel() {
    setup_canary
    assert_fails "feed_canary '$IMAGE' '$FX_URL/feed' '6.12.104~aa-r1'" "expected 'Installing kernel (6.12.104~aa-r1)'"
}

test_canary_fails_on_unsatisfiable_custom_dependency() {
    setup_canary
    fx_apk "$FEEDDIR/custom" broken 1.0-r1 "libc libmissing"
    feed_reindex "$FEEDDIR/custom" "$R"
    assert_fails "feed_canary '$IMAGE' '$FX_URL/feed' '$FX_KVER_DEFAULT'" "canary: apk add --simulate"
    assert_contains "$RUN_OUT" "libmissing"
}

test_canary_fails_on_image_without_feed_list() {
    setup_canary
    FX_NO_LIST=1 fx_build_outputs "$R" t1
    assert_fails "feed_canary '$IMAGE' '$FX_URL/feed' '$FX_KVER_DEFAULT'" "image has no x3000feed.list"
}
