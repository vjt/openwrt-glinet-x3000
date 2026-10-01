# Package metadata, signed indexes, signature checks.

test_pkg_tsv_reads_one_package() {
    fx_apk "$TEST_TMP/d" kmod-a 6.12.103-r1 "kernel=$FX_KVER_DEFAULT libc" feeds/base/kernel/linux
    local got
    got="$(feed_pkg_tsv "$TEST_TMP/d/kmod-a-6.12.103-r1.apk")"
    assert_eq "$got" "kmod-a"$'\t'"6.12.103-r1"$'\t'"feeds/base/kernel/linux"$'\t'"kernel=$FX_KVER_DEFAULT libc"
}

test_reindex_signs_with_the_tree_key() {
    fx_root "$TEST_TMP/root"
    fx_apk "$TEST_TMP/d" kmod-a 6.12.103-r1 "kernel=$FX_KVER_DEFAULT"
    fx_apk "$TEST_TMP/d" kernel "$FX_KVER_DEFAULT" libc
    feed_reindex "$TEST_TMP/d" "$TEST_TMP/root"
    assert_file "$TEST_TMP/d/packages.adb"
    assert_ok "feed_verify_index '$TEST_TMP/d/packages.adb' '$TEST_TMP/root/public-key.pem'"
}

test_index_tsv_lists_every_package() {
    fx_root "$TEST_TMP/root"
    fx_apk "$TEST_TMP/d" kmod-a 6.12.103-r1 "kernel=$FX_KVER_DEFAULT" feeds/base/kernel/linux
    fx_apk "$TEST_TMP/d" kernel "$FX_KVER_DEFAULT" libc feeds/base/kernel/linux
    feed_reindex "$TEST_TMP/d" "$TEST_TMP/root"
    local got
    got="$(feed_index_tsv "$TEST_TMP/d/packages.adb" | sort)"
    assert_eq "$got" "kernel"$'\t'"$FX_KVER_DEFAULT"$'\t'"feeds/base/kernel/linux"$'\t'"libc
kmod-a"$'\t'"6.12.103-r1"$'\t'"feeds/base/kernel/linux"$'\t'"kernel=$FX_KVER_DEFAULT"
}

test_verify_rejects_index_signed_with_another_key() {
    fx_root "$TEST_TMP/root"
    fx_key "$TEST_TMP/other"
    fx_apk "$TEST_TMP/d" x 1.0-r1
    feed_reindex "$TEST_TMP/d" "$TEST_TMP/other"
    assert_fails "feed_verify_index '$TEST_TMP/d/packages.adb' '$TEST_TMP/root/public-key.pem'" "is not signed by"
    assert_contains "$RUN_OUT" "UNTRUSTED"
}

test_verify_rejects_unsigned_index() {
    fx_root "$TEST_TMP/root"
    fx_apk "$TEST_TMP/d" x 1.0-r1
    ( cd "$TEST_TMP/d" && "$FEED_HOST_BIN/apk" mkndx --allow-untrusted --output packages.adb ./*.apk >/dev/null )
    assert_fails "feed_verify_index '$TEST_TMP/d/packages.adb' '$TEST_TMP/root/public-key.pem'" "is not signed by"
}

test_reindex_refuses_an_empty_dir() {
    fx_root "$TEST_TMP/root"
    mkdir -p "$TEST_TMP/d"
    assert_fails "feed_reindex '$TEST_TMP/d' '$TEST_TMP/root'" "no .apk in"
}
