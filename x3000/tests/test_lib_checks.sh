# Step 3 (artifact check) and step 4 (kernel consistency, refresh guard).

setup_outputs() {
    R="$TEST_TMP/root"
    B="$R/bin-x3000-public"
    fx_root "$R"
    fx_build_outputs "$R" t1
}

test_artifact_ok() {
    setup_outputs
    assert_ok "feed_check_artifact '$B' t1 '$R'"
}

test_artifact_needs_feed_tag() {
    setup_outputs
    rm "$B/FEED_TAG"
    assert_fails "feed_check_artifact '$B' t1 '$R'" "was not built with --release"
}

test_artifact_wrong_feed_tag() {
    fx_root "$TEST_TMP/root"
    FX_FEED_TAG=t0 fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" "FEED_TAG says 't0', expected 't1'"
}

test_artifact_without_feed_list() {
    fx_root "$TEST_TMP/root"
    FX_NO_LIST=1 fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" \
        "image has no /etc/apk/repositories.d/x3000feed.list"
}

test_artifact_list_for_another_tag() {
    fx_root "$TEST_TMP/root"
    FX_FEED_TAG=t1 fx_build_outputs "$TEST_TMP/root" t0
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" "does not point at tag t1"
}

test_artifact_trusting_another_key() {
    fx_root "$TEST_TMP/root"
    fx_key "$TEST_TMP/other"
    FX_IMAGE_PUB="$TEST_TMP/other/public-key.pem" fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" "does not trust"
}

test_artifact_private_variant() {
    fx_root "$TEST_TMP/root"
    FX_TELEGRAF=1 fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" "private variant"
}

test_artifact_without_fwtool_metadata() {
    fx_root "$TEST_TMP/root"
    FX_NO_METADATA=1 fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" "no fwtool metadata"
}

test_artifact_built_from_another_revision() {
    setup_outputs
    printf '#!/bin/sh\necho r101-fixture0002\n' > "$R/scripts/getver.sh"
    assert_fails "feed_check_artifact '$B' t1 '$R'" "image revision 'r100-fixture0001' is not this tree's 'r101-fixture0002'"
}

test_artifact_with_stale_base_files() {
    fx_root "$TEST_TMP/root"
    FX_STALE_BASEFILES=1 fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_artifact '$TEST_TMP/root/bin-x3000-public' t1 '$TEST_TMP/root'" "stale base-files"
}

test_manifest_kernel() {
    setup_outputs
    local got
    got="$(feed_manifest_kernel "$(feed_manifest_path "$B")")"
    assert_eq "$got" "$FX_KVER_DEFAULT"
}

test_manifest_kernel_needs_exactly_one_line() {
    printf 'base-files - 1\n' > "$TEST_TMP/m"
    assert_fails "feed_manifest_kernel '$TEST_TMP/m'" "exactly one 'kernel - <version>' line"
    printf 'kernel - 1\nkernel - 2\n' > "$TEST_TMP/m"
    assert_fails "feed_manifest_kernel '$TEST_TMP/m'" "exactly one 'kernel - <version>' line"
}

test_kmods_ok() {
    setup_outputs
    assert_ok "feed_check_kmods '$B/packages' '$FX_KVER_DEFAULT'"
}

test_kmods_with_foreign_kernel_dependency() {
    fx_root "$TEST_TMP/root"
    FX_FOREIGN_KMOD=1 fx_build_outputs "$TEST_TMP/root" t1
    assert_fails "feed_check_kmods '$TEST_TMP/root/bin-x3000-public/packages' '$FX_KVER_DEFAULT'" "kmods not built for kernel="
    assert_contains "$RUN_OUT" "kmod-foreign-6.12.103-r1"
}

test_kmods_against_another_kernel() {
    setup_outputs
    assert_fails "feed_check_kmods '$B/packages' '6.12.104~aa-r1'" "manifest says '6.12.104~aa-r1'"
}

test_kmods_with_two_kernel_packages() {
    setup_outputs
    fx_apk "$B/packages" kernel '6.12.103~ffffffffffffffffffffffffffffffff-r1' libc
    assert_fails "feed_check_kmods '$B/packages' '$FX_KVER_DEFAULT'" "holds kernel package(s)"
}

test_kmods_none_built() {
    mkdir -p "$TEST_TMP/p"
    assert_fails "feed_check_kmods '$TEST_TMP/p' '$FX_KVER_DEFAULT'" "no kmod-*.apk"
}

publish_kernel() {  # STAGE TAG KVER: a published kmods/<tag>/ for KVER
    fx_apk "$1/kmods/$2" kernel "$3" libc
    feed_reindex "$1/kmods/$2" "$TEST_TMP/root"
}

test_refresh_same_kernel_ok() {
    fx_root "$TEST_TMP/root"
    publish_kernel "$TEST_TMP/stage" t1 "$FX_KVER_DEFAULT"
    assert_ok "feed_check_refresh '$TEST_TMP/stage' t1 '$FX_KVER_DEFAULT'"
}

test_refresh_changed_kernel_refused() {
    fx_root "$TEST_TMP/root"
    publish_kernel "$TEST_TMP/stage" t1 "$FX_KVER_DEFAULT"
    assert_fails "feed_check_refresh '$TEST_TMP/stage' t1 '6.12.104~aa-r1'" "kernel changed → cut a new tag"
}

test_refresh_unpublished_tag_ok() {
    mkdir -p "$TEST_TMP/stage"
    assert_ok "feed_check_refresh '$TEST_TMP/stage' t1 '$FX_KVER_DEFAULT'"
}
